import Testing
import Foundation
import Darwin
@testable import KV_Studio

private actor StubManagedServer: ManagedServerHosting {
    let served: ConnectionEndpoint?
    private let pid: pid_t
    private let failure: ManagedServerError?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(pid: pid_t = 4_242, endpoint: ConnectionEndpoint? = nil, failure: ManagedServerError? = nil) {
        self.pid = pid
        self.served = endpoint
        self.failure = failure
    }

    func start() async throws -> pid_t {
        startCount += 1
        if let failure { throw failure }
        return pid
    }

    func stop() async {
        stopCount += 1
    }

    var endpoint: ConnectionEndpoint? { served }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ConnectionCoordinatorTests {

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-coordinator-\(UUID().uuidString)", isDirectory: true)
        let paths = ManagedPaths(root: root)
        try paths.createDirectoryTree()
        return paths
    }

    private func makeCoordinator(
        paths: ManagedPaths,
        server: any ManagedServerHosting = StubManagedServer(),
        budget: Duration = .milliseconds(800)
    ) -> ConnectionCoordinator {
        ConnectionCoordinator(
            paths: paths,
            server: server,
            probe: CompatibilityProbe(budget: budget),
            inspector: PortConflictInspector(budget: budget)
        )
    }

    private func compatibleServer() throws -> MultiFakeServer {
        try MultiFakeServer { peer in FakeKV.serve(peer) }
    }

    // MARK: - Existing targets

    @Test func connectingToACompatibleServerReachesConnectedAndOpensBothLanes() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let coordinator = makeCoordinator(paths: paths)

        await coordinator.connect(to: .existing(server.endpoint))

        #expect(coordinator.phase == .connected(
            ConnectionSession(target: .existing(server.endpoint), endpoint: server.endpoint)
        ))
        let browser = try #require(coordinator.browser)
        let console = try #require(coordinator.console)
        try await browser.ping()
        try await console.ping()
        #expect(coordinator.managedServer == .idle)
        #expect(PreferencesStore(paths: paths).loadLastConnectionTarget() == .existing(server.endpoint))
    }

    @Test func serverThatFailsTheProbeIsRejectedWithItsOutcomeAndIsNotRemembered() async throws {
        let paths = try makePaths()
        let coordinator = makeCoordinator(paths: paths)
        let hostile = try MultiFakeServer { peer in
            while let command = peer.readCommand() {
                if FakeKV.name(of: command) == "DBSIZE" {
                    peer.write(Data("-ERR unknown command 'DBSIZE'\r\n".utf8))
                } else {
                    peer.write(FakeKV.reply(to: command))
                }
            }
        }
        defer { hostile.stop() }

        await coordinator.connect(to: .existing(hostile.endpoint))

        #expect(coordinator.phase == .failed(ConnectionAttemptFailure(
            target: .existing(hostile.endpoint),
            failure: .rejected(hostile.endpoint, .incompatible(
                step: .dbSize,
                reason: .serverError(class: .unknownCommand, message: "ERR unknown command 'DBSIZE'")
            ))
        )))
        #expect(coordinator.browser == nil)
        #expect(coordinator.console == nil)
        #expect(PreferencesStore(paths: paths).loadLastConnectionTarget() == nil)
    }

    @Test func silentPeerIsSurfacedAsTheProbeReportedItWithoutExtraPrecision() async throws {
        let paths = try makePaths()
        let holder = try PortHolder()
        defer { holder.close() }
        let budget = Duration.milliseconds(300)
        let coordinator = makeCoordinator(paths: paths, budget: budget)

        await coordinator.connect(to: .existing(holder.endpoint))

        #expect(coordinator.phase == .failed(ConnectionAttemptFailure(
            target: .existing(holder.endpoint),
            failure: .rejected(holder.endpoint, .unreachable(.timedOut(step: .ping, budget: budget)))
        )))
    }

    @Test func browserAndConsoleLanesRunIndependently() async throws {
        let paths = try makePaths()
        let held = Signal()
        let release = DispatchSemaphore(value: 0)
        let server = try MultiFakeServer { peer in
            while let command = peer.readCommand() {
                if command.contains(Data("hold".utf8)) {
                    held.fire()
                    release.wait()
                }
                peer.write(FakeKV.reply(to: command))
            }
        }
        defer {
            release.signal()
            server.stop()
        }
        let coordinator = makeCoordinator(paths: paths)

        await coordinator.connect(to: .existing(server.endpoint))
        let browser = try #require(coordinator.browser)
        let console = try #require(coordinator.console)

        let traversal = Task { try await browser.scan(cursor: 0, match: Data("hold".utf8), count: 10) }
        await held.wait()

        // One shared connection would park this behind the SCAN until the suite time limit.
        try await console.ping()

        release.signal()
        let page = try await traversal.value
        #expect(page.keys.isEmpty)
    }

    @Test func switchingTargetsClosesTheConnectionsToThePreviousServer() async throws {
        let paths = try makePaths()
        let first = try compatibleServer()
        defer { first.stop() }
        let second = try compatibleServer()
        defer { second.stop() }
        let coordinator = makeCoordinator(paths: paths)

        await coordinator.connect(to: .existing(first.endpoint))
        let abandoned = try #require(coordinator.browser)

        await coordinator.connect(to: .existing(second.endpoint))

        #expect(coordinator.phase == .connected(
            ConnectionSession(target: .existing(second.endpoint), endpoint: second.endpoint)
        ))
        await #expect(throws: ConnectionError.notConnected) { try await abandoned.ping() }
        try await #require(coordinator.browser).ping()
    }

    // MARK: - Managed target

    @Test func connectingToTheManagedTargetStartsTheBackendThenConnects() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let host = StubManagedServer(pid: 991, endpoint: server.endpoint)
        let coordinator = makeCoordinator(paths: paths, server: host)

        await coordinator.connect(to: .managedLocal)

        #expect(await host.startCount == 1)
        #expect(coordinator.managedServer == .running(991))
        #expect(coordinator.phase == .connected(
            ConnectionSession(target: .managedLocal, endpoint: server.endpoint)
        ))
        #expect(PreferencesStore(paths: paths).loadLastConnectionTarget() == .managedLocal)
    }

    @Test func managedTargetWithoutAReportedEndpointFallsBackToThePreferredPort() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        try PreferencesStore(paths: paths).savePreferences(
            Preferences(localBindHost: "127.0.0.1", localPort: server.port)
        )
        let coordinator = makeCoordinator(paths: paths, server: StubManagedServer(endpoint: nil))

        await coordinator.connect(to: .managedLocal)

        #expect(coordinator.phase == .connected(
            ConnectionSession(target: .managedLocal, endpoint: server.endpoint)
        ))
    }

    @Test func portConflictSurfacesTheOccupantWithoutConnectingToIt() async throws {
        let paths = try makePaths()
        let occupant = try compatibleServer()
        defer { occupant.stop() }
        let host = StubManagedServer(endpoint: occupant.endpoint, failure: .portInUse(occupant.endpoint))
        let coordinator = makeCoordinator(paths: paths, server: host)

        await coordinator.connect(to: .managedLocal)

        #expect(coordinator.phase == .failed(ConnectionAttemptFailure(
            target: .managedLocal,
            failure: .portConflict(PortOccupancy(endpoint: occupant.endpoint, occupant: .compatible))
        )))
        #expect(coordinator.managedServer == .failed(.portInUse(occupant.endpoint)))
        #expect(coordinator.browser == nil)
        #expect(coordinator.console == nil)
        #expect(PreferencesStore(paths: paths).loadLastConnectionTarget() == nil)
    }

    @Test func managedStartFailureIsSurfacedAsIs() async throws {
        let paths = try makePaths()
        let host = StubManagedServer(failure: .binaryUnavailable(["/nowhere"]))
        let coordinator = makeCoordinator(paths: paths, server: host)

        await coordinator.connect(to: .managedLocal)

        #expect(coordinator.phase == .failed(ConnectionAttemptFailure(
            target: .managedLocal,
            failure: .managedServer(.binaryUnavailable(["/nowhere"]))
        )))
        #expect(coordinator.managedServer == .failed(.binaryUnavailable(["/nowhere"])))
    }

    // MARK: - Restore

    @Test func restoringReconnectsTheSavedTarget() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        try PreferencesStore(paths: paths).saveLastConnectionTarget(.existing(server.endpoint))
        let coordinator = makeCoordinator(paths: paths)

        await coordinator.restoreLastConnection()

        #expect(coordinator.phase == .connected(
            ConnectionSession(target: .existing(server.endpoint), endpoint: server.endpoint)
        ))
    }

    @Test func restoringWithNothingSavedTouchesNothing() async throws {
        let paths = try makePaths()
        let host = StubManagedServer()
        let coordinator = makeCoordinator(paths: paths, server: host)

        await coordinator.restoreLastConnection()

        #expect(coordinator.phase == .disconnected)
        #expect(coordinator.browser == nil)
        #expect(await host.startCount == 0)
        #expect(coordinator.managedServer == .idle)
    }

    @Test func reconnectRepeatsTheLastAttemptedTarget() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let coordinator = makeCoordinator(paths: paths)

        await coordinator.connect(to: .existing(server.endpoint))
        let first = try #require(coordinator.browser)
        await coordinator.reconnect()

        #expect(coordinator.phase == .connected(
            ConnectionSession(target: .existing(server.endpoint), endpoint: server.endpoint)
        ))
        await #expect(throws: ConnectionError.notConnected) { try await first.ping() }
    }

    // MARK: - Teardown

    @Test func shuttingDownClosesBothLanesAndStopsTheServerItStarted() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let host = StubManagedServer(endpoint: server.endpoint)
        let coordinator = makeCoordinator(paths: paths, server: host)

        await coordinator.connect(to: .managedLocal)
        let browser = try #require(coordinator.browser)
        let console = try #require(coordinator.console)

        await coordinator.shutDown()

        #expect(coordinator.phase == .disconnected)
        #expect(coordinator.browser == nil)
        #expect(coordinator.console == nil)
        await #expect(throws: ConnectionError.notConnected) { try await browser.ping() }
        await #expect(throws: ConnectionError.notConnected) { try await console.ping() }
        #expect(await host.stopCount == 1)
        #expect(coordinator.managedServer == .stopped)
    }

    @Test func shuttingDownLeavesAServerThisCoordinatorNeverStartedAlone() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let host = StubManagedServer()
        let coordinator = makeCoordinator(paths: paths, server: host)

        await coordinator.connect(to: .existing(server.endpoint))
        await coordinator.shutDown()

        #expect(await host.stopCount == 0)
        #expect(coordinator.managedServer == .idle)
        #expect(coordinator.phase == .disconnected)
    }

    @Test func aStopThatLeavesALiveRecordIsSurfacedAsUnreclaimedRatherThanStopped() async throws {
        let paths = try makePaths()
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let script = try await fixtures.launchableScript(named: "survivor", body: FixtureScript.sleepsForever)
        let survivor = Process()
        survivor.executableURL = script
        survivor.standardOutput = FileHandle.nullDevice
        survivor.standardError = FileHandle.nullDevice
        try survivor.run()
        defer {
            kill(survivor.processIdentifier, SIGKILL)
            survivor.waitUntilExit()
        }
        try await fixtures.waitUntilReady(script)

        let pid = survivor.processIdentifier
        let identity = try #require(ProcessIdentity.startTime(of: pid))
        let server = try compatibleServer()
        defer { server.stop() }
        try ManagedServerRecordStore(paths: paths).save(ManagedServerRecord(
            pid: pid,
            host: "127.0.0.1",
            port: server.port,
            binaryPath: script.path,
            processStartTime: identity,
            startedAt: Date()
        ))
        let host = StubManagedServer(pid: pid, endpoint: server.endpoint)
        let coordinator = makeCoordinator(paths: paths, server: host)

        await coordinator.connect(to: .managedLocal)
        await coordinator.shutDown()

        #expect(coordinator.managedServer == .unreclaimed(pid))
        #expect(coordinator.phase == .disconnected)
    }
}
