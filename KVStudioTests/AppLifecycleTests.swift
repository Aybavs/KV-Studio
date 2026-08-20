import Testing
import Foundation
@testable import KV_Studio

private func appSource(_ relative: String) -> String {
    let here = URL(filePath: #filePath)
    let root = here.deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent(relative)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

@Suite
struct AppLifecycleIntegrationTests {

    @Test func kvStudioAppRestoresLastConnectionOnLaunch() {
        let source = appSource("KVStudio/App/KVStudioApp.swift")
        #expect(source.contains("restoreLastConnection"), "KVStudioApp must trigger restoreLastConnection at launch")
    }

    @Test func kvStudioAppStopsManagedServerOnQuit() {
        let source = appSource("KVStudio/App/KVStudioApp.swift")
        let hasShutDown = source.contains("shutDown")
        let hasTerminationHook = source.contains("willTerminate") || source.contains("scenePhase") || source.contains("onChange") || source.contains("NSApplication")
        #expect(hasShutDown, "KVStudioApp must call shutDown on quit")
        #expect(hasTerminationHook, "KVStudioApp must observe termination via willTerminate or scenePhase")
    }

    @Test func appShellTriggersRestoreOnAppear() {
        let appSrc = appSource("KVStudio/App/KVStudioApp.swift")
        let shellSrc = appSource("KVStudio/App/AppShellView.swift")
        let combined = appSrc + shellSrc
        #expect(combined.contains("restoreLastConnection"), "App shell must restore last connection when the UI appears")
        #expect(combined.contains(".task") || combined.contains("onAppear"), "Restore must be driven by a SwiftUI lifecycle modifier")
    }
}

@Suite
@MainActor
struct ConnectionRestorationBehaviorTests {

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-restore-\(UUID().uuidString)", isDirectory: true)
        let paths = ManagedPaths(root: root)
        try paths.createDirectoryTree()
        return paths
    }

    private func compatibleServer() throws -> FakeServer {
        try FakeServer(maxPeers: 8) { peer in FakeKV.serve(peer) }
    }

    @Test func restoringManagedLocalAutoStartsAndShowsBrowserPhase() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let host = StubLifecycleHost(pid: 4242, endpoint: server.endpoint)
        let coordinator = ConnectionCoordinator(
            paths: paths,
            server: host,
            probe: CompatibilityProbe(budget: .milliseconds(800)),
            inspector: PortConflictInspector(budget: .milliseconds(800)),
            opener: KVConnectionLaneOpener()
        )
        try PreferencesStore(paths: paths).saveLastConnectionTarget(.managedLocal)

        await coordinator.restoreLastConnection()

        #expect(await host.startCount == 1)
        guard case .connected(let session) = coordinator.phase else {
            Issue.record("expected connected after restoring managedLocal, got \(coordinator.phase)")
            return
        }
        #expect(session.target == .managedLocal)
        #expect(coordinator.browser != nil)
        #expect(coordinator.console != nil)
        #expect(onboardingErrorMessage(for: coordinator.phase) == nil)
    }

    @Test func restoringExistingReconnectsAndShowsBrowserPhase() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let coordinator = ConnectionCoordinator(
            paths: paths,
            server: StubLifecycleHost(endpoint: server.endpoint),
            probe: CompatibilityProbe(budget: .milliseconds(800)),
            inspector: PortConflictInspector(budget: .milliseconds(800)),
            opener: KVConnectionLaneOpener()
        )
        try PreferencesStore(paths: paths).saveLastConnectionTarget(.existing(server.endpoint))

        await coordinator.restoreLastConnection()

        guard case .connected(let session) = coordinator.phase else {
            Issue.record("expected connected after restoring existing, got \(coordinator.phase)")
            return
        }
        #expect(session.target == .existing(server.endpoint))
        #expect(coordinator.browser != nil)
        #expect(onboardingErrorMessage(for: coordinator.phase) == nil)
    }

    @Test func restoringUnreachableShowsConnectionScreenWithContext() async throws {
        let paths = try makePaths()
        let holder = try PortHolder()
        defer { holder.close() }
        let coordinator = ConnectionCoordinator(
            paths: paths,
            server: StubLifecycleHost(),
            probe: CompatibilityProbe(budget: .milliseconds(500)),
            inspector: PortConflictInspector(budget: .milliseconds(500)),
            opener: KVConnectionLaneOpener()
        )
        try PreferencesStore(paths: paths).saveLastConnectionTarget(.existing(holder.endpoint))

        await coordinator.restoreLastConnection()

        guard case .failed(let attempt) = coordinator.phase else {
            Issue.record("expected failed after restoring to unreachable endpoint, got \(coordinator.phase)")
            return
        }
        #expect(attempt.target == .existing(holder.endpoint))
        #expect(coordinator.browser == nil)
        let message = onboardingErrorMessage(for: coordinator.phase)
        #expect(message != nil, "Connection screen must show failure context")
        #expect(!(message?.isEmpty ?? true))
    }

    @Test func appQuitGracefullyStopsManagedServer() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let host = StubLifecycleHost(pid: 991, endpoint: server.endpoint)
        let coordinator = ConnectionCoordinator(
            paths: paths,
            server: host,
            probe: CompatibilityProbe(budget: .milliseconds(800)),
            inspector: PortConflictInspector(budget: .milliseconds(800)),
            opener: KVConnectionLaneOpener()
        )
        await coordinator.connect(to: .managedLocal)
        #expect(await host.startCount == 1)

        await coordinator.shutDown()

        #expect(await host.stopCount == 1)
        #expect(coordinator.phase == .disconnected)
        #expect(coordinator.browser == nil)
        #expect(coordinator.console == nil)
    }
}

private actor StubLifecycleHost: ManagedServerHosting {
    nonisolated var outputLines: AsyncStream<String> { AsyncStream { $0.finish() } }
    private let handle: ManagedServerHandle?
    private let failure: (any Error)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(pid: pid_t = 4242, endpoint: ConnectionEndpoint = ConnectionEndpoint(host: "127.0.0.1", port: 1), failure: (any Error)? = nil) {
        self.handle = ManagedServerHandle(pid: pid, endpoint: endpoint)
        self.failure = failure
    }

    init(failure: (any Error)? = nil) {
        self.handle = nil
        self.failure = failure
    }

    func start() async throws -> ManagedServerHandle {
        startCount += 1
        if let failure { throw failure }
        guard let handle else { throw ManagedServerError.binaryUnavailable(["/nowhere"]) }
        return handle
    }

    func stop() async -> ManagedServerStopOutcome {
        stopCount += 1
        return .stopped
    }
}
