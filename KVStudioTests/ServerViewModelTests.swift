import Testing
import Foundation
import Darwin
@testable import KV_Studio

@Suite
@MainActor
struct ServerViewModelManagedTests {

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-server-vm-\(UUID().uuidString)", isDirectory: true)
        let paths = ManagedPaths(root: root)
        try paths.createDirectoryTree()
        return paths
    }

    private func makeCoordinator(paths: ManagedPaths, managedStatus: ManagedServerStatus = .idle, phase: ConnectionPhase = .disconnected, endpoint: ConnectionEndpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)) throws -> ConnectionCoordinator {
        // Use stub server to control managed status via coordinator's published state?
        // Instead we directly craft coordinator and then set via reflection? We test static helpers.
        return ConnectionCoordinator(paths: paths, server: StubServerForViewModel())
    }

    @Test func managedIsTrueWhenDisconnected() {
        #expect(ServerViewModel.isManaged(phase: .disconnected) == true)
    }

    @Test func managedIsTrueWhenConnectingManaged() {
        #expect(ServerViewModel.isManaged(phase: .connecting(.managedLocal)) == true)
    }

    @Test func managedIsFalseWhenConnectingExisting() {
        let ep = ConnectionEndpoint(host: "10.0.0.5", port: 6379)
        #expect(ServerViewModel.isManaged(phase: .connecting(.existing(ep))) == false)
    }

    @Test func managedIsFalseWhenConnectedExisting() {
        let ep = ConnectionEndpoint(host: "10.0.0.5", port: 6379)
        let session = ConnectionSession(target: .existing(ep), endpoint: ep)
        #expect(ServerViewModel.isManaged(phase: .connected(session)) == false)
    }

    @Test func managedIsTrueWhenConnectedManagedLocal() {
        let ep = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let session = ConnectionSession(target: .managedLocal, endpoint: ep)
        #expect(ServerViewModel.isManaged(phase: .connected(session)) == true)
    }

    @Test func stateTextForIdleIsStopped() {
        #expect(ServerViewModel.stateText(managedServer: .idle, phase: .disconnected) == "Stopped")
    }

    @Test func stateTextForStarting() {
        #expect(ServerViewModel.stateText(managedServer: .starting, phase: .disconnected) == "Starting")
        #expect(ServerViewModel.stateText(managedServer: .starting, phase: .connecting(.managedLocal)) == "Starting")
    }

    @Test func stateTextForRunning() {
        #expect(ServerViewModel.stateText(managedServer: .running(1234), phase: .disconnected) == "Running")
    }

    @Test func stateTextForStopping() {
        #expect(ServerViewModel.stateText(managedServer: .stopping, phase: .disconnected) == "Stopping")
    }

    @Test func stateTextForStopped() {
        #expect(ServerViewModel.stateText(managedServer: .stopped, phase: .disconnected) == "Stopped")
    }

    @Test func stateTextForFailedContainsDescription() {
        let text = ServerViewModel.stateText(managedServer: .failed(.binaryUnavailable(["/a"])), phase: .disconnected)
        #expect(text.hasPrefix("Failed"))
    }

    @Test func stateTextForUnreclaimed() {
        let text = ServerViewModel.stateText(managedServer: .unreclaimed(999), phase: .disconnected)
        #expect(text.contains("999"))
        #expect(text.contains("unreclaimed"))
    }

    @Test func pidTextForRunning() {
        #expect(ServerViewModel.pidText(managedServer: .running(42)) == "42")
    }

    @Test func pidTextForUnreclaimed() {
        let text = ServerViewModel.pidText(managedServer: .unreclaimed(77))
        #expect(text.contains("77"))
    }

    @Test func pidTextForIdleIsDash() {
        #expect(ServerViewModel.pidText(managedServer: .idle) == "—")
        #expect(ServerViewModel.pidText(managedServer: .stopped) == "—")
        #expect(ServerViewModel.pidText(managedServer: .starting) == "—")
        #expect(ServerViewModel.pidText(managedServer: .failed(.binaryUnavailable([]))) == "—")
    }

    @Test func backendVersionLoadsFromMetadata() throws {
        let paths = try makePaths()
        let meta = ["version": "1.2.3"]
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: paths.backendCurrentMetadata)
        #expect(ServerViewModel.loadBackendVersion(from: paths.backendCurrentMetadata) == "1.2.3")
    }

    @Test func backendVersionNilWhenMissing() throws {
        let paths = try makePaths()
        #expect(ServerViewModel.loadBackendVersion(from: paths.backendCurrentMetadata) == nil)
    }

    @Test func aofSizeLoadsWhenFileExists() throws {
        let paths = try makePaths()
        let content = Data("hello".utf8)
        try content.write(to: paths.aofFile)
        let size = ServerViewModel.loadAOFSize(at: paths.aofFile)
        #expect(size == 5)
    }

    @Test func aofSizeNilWhenMissing() throws {
        let paths = try makePaths()
        #expect(ServerViewModel.loadAOFSize(at: paths.aofFile) == nil)
    }

    @Test func formatAOFSizeHumanReadable() {
        #expect(ServerViewModel.formatAOFSize(nil) == "—")
        #expect(ServerViewModel.formatAOFSize(0) == "0 B")
        #expect(ServerViewModel.formatAOFSize(500) == "500 B")
        #expect(ServerViewModel.formatAOFSize(1536) == "1.5 KB")
        #expect(ServerViewModel.formatAOFSize(1024*1024) == "1.0 MB")
    }

    @Test func aofModeText() throws {
        let paths = try makePaths()
        let stub = StubServerForViewModel()
        let coordinator = ConnectionCoordinator(paths: paths, server: stub)
        let vm = ServerViewModel(paths: paths, coordinator: coordinator)
        #expect(vm.aofModeText == "AOF enabled — appendfsync everysec")
    }

    @Test func hostPortUsesPreferencesWhenManagedDisconnected() {
        let text = ServerViewModel.hostPortText(phase: .disconnected, preferences: .default)
        #expect(text == "127.0.0.1:6380")
    }

    @Test func hostPortUsesSessionWhenConnected() {
        let endpoint = ConnectionEndpoint(host: "10.0.0.5", port: 7000)
        let session = ConnectionSession(target: .existing(endpoint), endpoint: endpoint)
        let text = ServerViewModel.hostPortText(phase: .connected(session), preferences: .default)
        #expect(text == "10.0.0.5:7000")
    }

    @Test func hostPortUsesTheTargetWhileConnectingToAnExistingServer() {
        let endpoint = ConnectionEndpoint(host: "192.168.1.9", port: 6399)
        let text = ServerViewModel.hostPortText(phase: .connecting(.existing(endpoint)), preferences: .default)
        #expect(text == "192.168.1.9:6399")
    }

    @Test func hostPortFallsBackToPreferencesForAManagedTarget() {
        let preferences = Preferences(localBindHost: "127.0.0.1", localPort: 7777)
        let text = ServerViewModel.hostPortText(phase: .connecting(.managedLocal), preferences: preferences)
        #expect(text == "127.0.0.1:7777")
    }

    @Test func binaryAndDataPathsExposed() throws {
        let paths = try makePaths()
        let stub = StubServerForViewModel()
        let coordinator = ConnectionCoordinator(paths: paths, server: stub)
        let vm = ServerViewModel(paths: paths, coordinator: coordinator)
        #expect(vm.binaryPathText == paths.backendCurrentBinary.path)
        #expect(vm.dataPathText == paths.dataDir.path)
        #expect(vm.aofPathText == paths.aofFile.path)
    }

    @Test func canStartWhenIdle() throws {
        let paths = try makePaths()
        let stub = StubServerForViewModel()
        let coordinator = ConnectionCoordinator(paths: paths, server: stub)
        let vm = ServerViewModel(paths: paths, coordinator: coordinator)
        // managed idle, disconnected -> canStart true
        #expect(vm.canStart == true)
        #expect(vm.canStop == false)
    }

    @Test func disconnectAllowsReconnectToManaged() async throws {
        let paths = try makePaths()
        let server = try FakeServer(maxPeers: 8) { peer in FakeKV.serve(peer) }
        defer { server.stop() }
        let stub = StubServerForViewModel(endpoint: server.endpoint)
        let coordinator = ConnectionCoordinator(paths: paths, server: stub)
        await coordinator.connect(to: .managedLocal)
        #expect(coordinator.managedServer == .running(1))
        if case .connected(let session) = coordinator.phase {
            #expect(session.target == .managedLocal)
        } else {
            Issue.record("expected connected after managed start")
        }
        await coordinator.disconnect()
        #expect(coordinator.phase == .disconnected)
        #expect(coordinator.managedServer == .stopped)
        #expect(coordinator.browser == nil)
        // Reconnect should succeed again
        await coordinator.connect(to: .managedLocal)
        #expect(coordinator.managedServer == .running(1))
        if case .connected = coordinator.phase { } else { Issue.record("expected reconnected") }
    }

    @Test func disconnectAfterExistingDoesNotStopManagedItNeverStarted() async throws {
        let paths = try makePaths()
        let server = try FakeServer(maxPeers: 8) { peer in FakeKV.serve(peer) }
        defer { server.stop() }
        let stub = StubServerForViewModel()
        let coordinator = ConnectionCoordinator(paths: paths, server: stub)
        await coordinator.connect(to: .existing(server.endpoint))
        #expect(coordinator.phase == .connected(ConnectionSession(target: .existing(server.endpoint), endpoint: server.endpoint)))
        await coordinator.disconnect()
        #expect(coordinator.phase == .disconnected)
        #expect(await stub.stopCount == 0)
    }

    @Test func compatibilityTextIsExpected() throws {
        let paths = try makePaths()
        let coordinator = ConnectionCoordinator(paths: paths, server: StubServerForViewModel())
        let vm = ServerViewModel(paths: paths, coordinator: coordinator)
        #expect(vm.compatibilityText.contains("Compatible"))
    }
}

private actor StubServerForViewModel: ManagedServerHosting {
    nonisolated var outputLines: AsyncStream<String> { AsyncStream { $0.finish() } }
    let endpoint: ConnectionEndpoint
    private(set) var stopCount = 0
    init(endpoint: ConnectionEndpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)) {
        self.endpoint = endpoint
    }
    func start() async throws -> ManagedServerHandle { ManagedServerHandle(pid: 1, endpoint: endpoint) }
    func stop() async -> ManagedServerStopOutcome { stopCount += 1; return .stopped }
}
