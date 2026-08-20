import Foundation
import Observation

protocol BackendReleaseDiscovering: Sendable {
    func latest() async throws -> BackendRelease
}

protocol BackendStaging: Sendable {
    func stage(_ release: BackendRelease) async throws -> BackendStagedStaging
}

protocol BackendActivating: Sendable {
    func activate() async throws -> BackendActivation
}

extension BackendReleaseLookup: BackendReleaseDiscovering {}
extension BackendStager: BackendStaging {}
extension BackendActivator: BackendActivating {}

// One card, one button. The plan's rule is that a backend the new Studio needs must be staged
// BEFORE Studio relaunches, because after the relaunch the new Studio is the one that activates it.
@MainActor
@Observable
final class UpdateCoordinator {
    private(set) var state: UpdateState = .idle

    @ObservationIgnored private let paths: ManagedPaths
    @ObservationIgnored private let releases: any BackendReleaseDiscovering
    @ObservationIgnored private let stager: any BackendStaging
    @ObservationIgnored private let activator: any BackendActivating
    @ObservationIgnored private let appUpdater: any AppUpdating

    init(
        paths: ManagedPaths,
        releases: any BackendReleaseDiscovering,
        stager: any BackendStaging,
        activator: any BackendActivating,
        appUpdater: any AppUpdating
    ) {
        self.paths = paths
        self.releases = releases
        self.stager = stager
        self.activator = activator
        self.appUpdater = appUpdater
    }

    // MARK: - Checking

    func check() async {
        state = .checking
        let installed = Self.installedBackendVersion(at: paths)
        var available: SemanticVersion?
        do {
            available = try await releases.latest().version
        } catch {
            state = .failed(Self.message(for: error))
            return
        }
        let plan = UpdatePlan(
            studioVersion: appUpdater.availableVersion,
            installedBackend: installed,
            availableBackend: available
        )
        state = plan.hasAnything ? .updateAvailable(plan) : .completed
    }

    // MARK: - Updating

    func updateEverything() async {
        guard case .updateAvailable(let plan) = state else { return }

        if plan.hasBackendUpdate {
            do {
                state = .downloadingBackend
                let release = try await releases.latest()
                state = .stagingBackend
                _ = try await stager.stage(release)
            } catch {
                state = .failed(Self.message(for: error))
                return
            }
        }

        guard plan.hasStudioUpdate else {
            await activateStagedBackend()
            return
        }

        // Sparkle owns the app half; the staged backend waits on disk until the new Studio starts.
        state = .stagingApp
        appUpdater.checkForUpdates()
        state = .relaunchRequired
    }

    // MARK: - Completing after a relaunch

    func activateStagedBackendIfPresent() async {
        guard Self.hasStagedBackend(at: paths) else { return }
        await activateStagedBackend()
    }

    private func activateStagedBackend() async {
        state = .stoppingServer
        do {
            state = .activatingBackend
            _ = try await activator.activate()
            state = .completed
        } catch let error as BackendActivationError {
            switch error {
            case .rolledBack(let reason):
                state = .rolledBack(reason)
            default:
                state = .failed(Self.message(for: error))
            }
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    // Called by the activator's onVerifying hook, so `.verifying` reflects the real probe rather
    // than being set and immediately overwritten.
    func noteVerifying() {
        guard state == .activatingBackend else { return }
        state = .verifying
    }

    func dismiss() {
        state = .idle
    }

    // MARK: - Reading what is installed

    static func installedBackendVersion(at paths: ManagedPaths) -> SemanticVersion? {
        guard let data = try? Data(contentsOf: paths.backendCurrentMetadata),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["version"] as? String else { return nil }
        return SemanticVersion(string: text)
    }

    static func hasStagedBackend(at paths: ManagedPaths) -> Bool {
        FileManager.default.isExecutableFile(
            atPath: paths.backendStagingDir.appendingPathComponent(BackendArchiveLayout.executableName).path
        )
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
