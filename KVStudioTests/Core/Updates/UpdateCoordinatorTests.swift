import Foundation
import Testing
@testable import KV_Studio

private struct StubReleases: BackendReleaseDiscovering {
    let version: String?
    let failure: (any Error)?

    init(version: String? = "1.2.0", failure: (any Error)? = nil) {
        self.version = version
        self.failure = failure
    }

    func latest() async throws -> BackendRelease {
        if let failure { throw failure }
        return BackendRelease(
            version: SemanticVersion(string: version!)!,
            archive: BackendReleaseAsset(name: "a.tar.gz", url: URL(string: "https://example.invalid/a")!, size: 1),
            checksums: BackendReleaseAsset(name: "SHA256SUMS", url: URL(string: "https://example.invalid/s")!, size: 1)
        )
    }
}

private final class StubStager: BackendStaging, @unchecked Sendable {
    private(set) var staged = 0
    let failure: (any Error)?

    init(failure: (any Error)? = nil) { self.failure = failure }

    func stage(_ release: BackendRelease) async throws -> BackendStagedStaging {
        staged += 1
        if let failure { throw failure }
        return BackendStagedStaging(
            executable: URL(fileURLWithPath: "/tmp/kv-server"),
            metadata: URL(fileURLWithPath: "/tmp/metadata.json"),
            version: release.version,
            sha256: String(repeating: "a", count: 64)
        )
    }
}

private final class StubActivator: BackendActivating, @unchecked Sendable {
    private(set) var activations = 0
    let failure: (any Error)?

    init(failure: (any Error)? = nil) { self.failure = failure }

    func activate() async throws -> BackendActivation {
        activations += 1
        if let failure { throw failure }
        return BackendActivation(
            version: SemanticVersion(string: "1.2.0")!,
            endpoint: ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        )
    }
}

@MainActor
private final class StubAppUpdater: AppUpdating {
    var canCheckForUpdates = true
    var availableVersion: String?
    private(set) var checks = 0

    init(availableVersion: String? = nil) { self.availableVersion = availableVersion }

    func checkForUpdates() { checks += 1 }
}

@MainActor
@Suite
struct UpdateCoordinatorTests {

    private func makePaths(installedBackend: String? = nil, staged: Bool = false) throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-update-\(UUID().uuidString)", isDirectory: true)
        let paths = ManagedPaths(root: root)
        try paths.createDirectoryTree()
        if let installedBackend {
            try JSONSerialization.data(withJSONObject: ["version": installedBackend])
                .write(to: paths.backendCurrentMetadata)
        }
        if staged {
            let binary = paths.backendStagingDir.appendingPathComponent("kv-server")
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return paths
    }

    private func makeCoordinator(
        paths: ManagedPaths,
        releases: StubReleases = StubReleases(),
        stager: StubStager = StubStager(),
        activator: StubActivator = StubActivator(),
        appUpdater: StubAppUpdater = StubAppUpdater()
    ) -> UpdateCoordinator {
        UpdateCoordinator(
            paths: paths,
            releases: releases,
            stager: stager,
            activator: activator,
            appUpdater: appUpdater
        )
    }

    // MARK: - Checking

    @Test func findsABackendUpdateWhenTheReleaseIsNewer() async throws {
        let paths = try makePaths(installedBackend: "1.1.0")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let coordinator = makeCoordinator(paths: paths)

        await coordinator.check()

        guard case .updateAvailable(let plan) = coordinator.state else {
            Issue.record("expected an available update, got \(coordinator.state)")
            return
        }
        #expect(plan.hasBackendUpdate)
        #expect(plan.installedBackend == SemanticVersion(string: "1.1.0"))
        #expect(plan.availableBackend == SemanticVersion(string: "1.2.0"))
    }

    @Test func reportsNothingToDoWhenTheBackendIsCurrent() async throws {
        let paths = try makePaths(installedBackend: "1.2.0")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let coordinator = makeCoordinator(paths: paths)

        await coordinator.check()

        #expect(coordinator.state == .completed)
    }

    @Test func treatsAMissingInstalledBackendAsNeedingTheRelease() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let coordinator = makeCoordinator(paths: paths)

        await coordinator.check()

        guard case .updateAvailable(let plan) = coordinator.state else {
            Issue.record("expected an available update, got \(coordinator.state)")
            return
        }
        #expect(plan.hasBackendUpdate)
    }

    @Test func surfacesALookupFailure() async throws {
        let paths = try makePaths(installedBackend: "1.1.0")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let coordinator = makeCoordinator(paths: paths, releases: StubReleases(failure: BackendReleaseError.unreadableResponse))

        await coordinator.check()

        guard case .failed = coordinator.state else {
            Issue.record("expected a failure, got \(coordinator.state)")
            return
        }
    }

    // MARK: - Updating

    @Test func backendOnlyUpdateStagesThenActivates() async throws {
        let paths = try makePaths(installedBackend: "1.1.0")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let stager = StubStager()
        let activator = StubActivator()
        let coordinator = makeCoordinator(paths: paths, stager: stager, activator: activator)

        await coordinator.check()
        await coordinator.updateEverything()

        #expect(stager.staged == 1)
        #expect(activator.activations == 1)
        #expect(coordinator.state == .completed)
    }

    // The plan's rule: a backend the new Studio needs must be on disk before Studio relaunches.
    @Test func stagesTheBackendBeforeAskingStudioToRelaunch() async throws {
        let paths = try makePaths(installedBackend: "1.1.0")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let stager = StubStager()
        let activator = StubActivator()
        let updater = StubAppUpdater(availableVersion: "0.2.0")
        let coordinator = makeCoordinator(paths: paths, stager: stager, activator: activator, appUpdater: updater)

        await coordinator.check()
        await coordinator.updateEverything()

        #expect(stager.staged == 1)
        #expect(updater.checks == 1)
        #expect(coordinator.state == .relaunchRequired)
        // Activation is the NEW Studio's job, after the relaunch.
        #expect(activator.activations == 0)
    }

    @Test func aStagingFailureStopsBeforeTouchingTheApp() async throws {
        let paths = try makePaths(installedBackend: "1.1.0")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let updater = StubAppUpdater(availableVersion: "0.2.0")
        let coordinator = makeCoordinator(
            paths: paths,
            stager: StubStager(failure: BackendStagingError.checksumMissing("a.tar.gz")),
            appUpdater: updater
        )

        await coordinator.check()
        await coordinator.updateEverything()

        guard case .failed = coordinator.state else {
            Issue.record("expected a failure, got \(coordinator.state)")
            return
        }
        #expect(updater.checks == 0)
    }

    @Test func ignoresUpdateEverythingWhenNothingWasOffered() async throws {
        let paths = try makePaths(installedBackend: "1.1.0")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let stager = StubStager()
        let coordinator = makeCoordinator(paths: paths, stager: stager)

        await coordinator.updateEverything()

        #expect(stager.staged == 0)
        #expect(coordinator.state == .idle)
    }

    // MARK: - After a relaunch

    @Test func theNewStudioActivatesWhatThePreviousOneStaged() async throws {
        let paths = try makePaths(installedBackend: "1.1.0", staged: true)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let activator = StubActivator()
        let coordinator = makeCoordinator(paths: paths, activator: activator)

        await coordinator.activateStagedBackendIfPresent()

        #expect(activator.activations == 1)
        #expect(coordinator.state == .completed)
    }

    @Test func doesNothingAtLaunchWhenNothingIsStaged() async throws {
        let paths = try makePaths(installedBackend: "1.1.0")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let activator = StubActivator()
        let coordinator = makeCoordinator(paths: paths, activator: activator)

        await coordinator.activateStagedBackendIfPresent()

        #expect(activator.activations == 0)
        #expect(coordinator.state == .idle)
    }

    @Test func reportsARollbackDistinctlyFromAFailure() async throws {
        let paths = try makePaths(installedBackend: "1.1.0", staged: true)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let coordinator = makeCoordinator(
            paths: paths,
            activator: StubActivator(failure: BackendActivationError.rolledBack("probe said no"))
        )

        await coordinator.activateStagedBackendIfPresent()

        #expect(coordinator.state == .rolledBack("probe said no"))
    }

    @Test func reportsAnUnrecoverableActivationAsAFailure() async throws {
        let paths = try makePaths(installedBackend: "1.1.0", staged: true)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let coordinator = makeCoordinator(
            paths: paths,
            activator: StubActivator(failure: BackendActivationError.rollbackFailed(reason: "no start", detail: "no previous"))
        )

        await coordinator.activateStagedBackendIfPresent()

        guard case .failed = coordinator.state else {
            Issue.record("expected a failure, got \(coordinator.state)")
            return
        }
    }

    @Test func verifyingIsOnlyReportedWhileActivating() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let coordinator = makeCoordinator(paths: paths)

        coordinator.noteVerifying()
        #expect(coordinator.state == .idle)
    }

    @Test func knowsWhichStatesAreBusy() {
        #expect(UpdateState.downloadingBackend.isBusy)
        #expect(UpdateState.verifying.isBusy)
        #expect(UpdateState.relaunchRequired.isBusy == false)
        #expect(UpdateState.completed.isBusy == false)
    }
}
