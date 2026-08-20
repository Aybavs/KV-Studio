import Foundation

struct BackendActivation: Equatable, Sendable {
    let version: SemanticVersion
    let endpoint: ConnectionEndpoint
}

enum BackendActivationError: Error, Equatable {
    case nothingStaged
    case swapFailed(String)
    case rolledBack(String)
    case rollbackFailed(reason: String, detail: String)
}

extension BackendActivationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .nothingStaged:
            return "There is no verified backend waiting to be installed."
        case .swapFailed(let detail):
            return "The backend could not be swapped in: \(detail)"
        case .rolledBack(let reason):
            return "The new backend did not work, so the previous one was restored. \(reason)"
        case .rollbackFailed(let reason, let detail):
            return "The new backend failed (\(reason)) and the previous one could not be restored: \(detail)"
        }
    }
}

protocol BackendProbing: Sendable {
    func probe(_ endpoint: ConnectionEndpoint) async throws -> CompatibilityOutcome
}

struct CompatibilityProbeAdapter: BackendProbing {
    let probe: CompatibilityProbe

    init(probe: CompatibilityProbe = CompatibilityProbe()) { self.probe = probe }

    func probe(_ endpoint: ConnectionEndpoint) async throws -> CompatibilityOutcome {
        try await probe.run(against: endpoint)
    }
}

// Every step is a rename within Application Support, so each one is atomic on its own volume; the
// value of that is that a failure can always be undone by renaming back.
struct BackendActivator: Sendable {
    let paths: ManagedPaths
    let host: any ManagedServerHosting
    let prober: any BackendProbing

    init(paths: ManagedPaths, host: any ManagedServerHosting, prober: any BackendProbing = CompatibilityProbeAdapter()) {
        self.paths = paths
        self.host = host
        self.prober = prober
    }

    func activate() async throws -> BackendActivation {
        let staged = paths.backendStagingDir.appendingPathComponent(BackendArchiveLayout.executableName)
        guard FileManager.default.isExecutableFile(atPath: staged.path) else {
            throw BackendActivationError.nothingStaged
        }
        let version = try stagedVersion()

        _ = await host.stop()
        try swapInStaged()

        do {
            let handle = try await host.start()
            let outcome = try await prober.probe(handle.endpoint)
            guard outcome == .compatible else {
                throw BackendActivationError.rolledBack("The server reported \(outcome).")
            }
            return BackendActivation(version: version, endpoint: handle.endpoint)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try await restorePrevious(reason: reason)
            throw BackendActivationError.rolledBack(reason)
        }
    }

    // MARK: - Steps

    private func stagedVersion() throws -> SemanticVersion {
        let file = paths.backendStagingDir.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["version"] as? String,
              let version = SemanticVersion(string: text) else {
            throw BackendActivationError.nothingStaged
        }
        return version
    }

    private func swapInStaged() throws {
        let manager = FileManager.default
        do {
            try? manager.removeItem(at: paths.backendPreviousDir)
            if manager.fileExists(atPath: paths.backendCurrentDir.path) {
                try manager.moveItem(at: paths.backendCurrentDir, to: paths.backendPreviousDir)
            }
            try manager.moveItem(at: paths.backendStagingDir, to: paths.backendCurrentDir)
            try manager.createDirectory(at: paths.backendStagingDir, withIntermediateDirectories: true)
        } catch {
            throw BackendActivationError.swapFailed(error.localizedDescription)
        }
    }

    private func restorePrevious(reason: String) async throws {
        _ = await host.stop()
        let manager = FileManager.default
        guard manager.fileExists(atPath: paths.backendPreviousDir.path) else {
            throw BackendActivationError.rollbackFailed(reason: reason, detail: "there is no previous backend to restore")
        }
        do {
            try? manager.removeItem(at: paths.backendCurrentDir)
            try manager.moveItem(at: paths.backendPreviousDir, to: paths.backendCurrentDir)
        } catch {
            throw BackendActivationError.rollbackFailed(reason: reason, detail: error.localizedDescription)
        }
        // Best effort: the previous backend was working before this attempt, so a failure to bring
        // it back up is reported through the coordinator's own state rather than swallowed here.
        _ = try? await host.start()
    }
}
