import Testing
import Foundation
import Darwin
@testable import KV_Studio

// ManagedServerController.start() cannot be cancelled from the outside, so a gate that unparks
// on cancellation would model something easier than the real thing.
private final class StartLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        isOpen = true
        let parked = waiting
        waiting = []
        lock.unlock()
        parked.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }
}

private actor StubManagedServer: ManagedServerHosting {
    private let handle: ManagedServerHandle
    private let failure: (any Error)?
    private let gate: StartLatch?
    private let stopOutcome: ManagedServerStopOutcome
    private let entered = Signal()
    private var liveStarts = 0

    nonisolated var outputLines: AsyncStream<String> { AsyncStream { $0.finish() } }

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var maxConcurrentStarts = 0

    init(
        pid: pid_t = 4_242,
        endpoint: ConnectionEndpoint = ConnectionEndpoint(host: "127.0.0.1", port: 1),
        failure: (any Error)? = nil,
        gate: StartLatch? = nil,
        stopOutcome: ManagedServerStopOutcome = .stopped
    ) {
        self.handle = ManagedServerHandle(pid: pid, endpoint: endpoint)
        self.failure = failure
        self.gate = gate
        self.stopOutcome = stopOutcome
    }

    func start() async throws -> ManagedServerHandle {
        startCount += 1
        liveStarts += 1
        maxConcurrentStarts = max(maxConcurrentStarts, liveStarts)
        entered.fire()
        await Task.yield()
        maxConcurrentStarts = max(maxConcurrentStarts, liveStarts)
        if let gate { await gate.wait() }
        liveStarts -= 1
        if let failure { throw failure }
        return handle
    }

    // Models ManagedServerController.stop(), which cancels a live start from the inside.
    func stop() async -> ManagedServerStopOutcome {
        stopCount += 1
        gate?.open()
        return stopOutcome
    }

    func waitUntilStarting() async {
        await entered.wait()
    }
}

private actor SecondLaneFails: ConnectionLaneOpening {
    private(set) var opened: [KVConnection] = []

    func open(to endpoint: ConnectionEndpoint) async throws -> KVConnection {
        guard opened.isEmpty else { throw ConnectionError.connectFailed("second lane refused") }
        let connection = KVConnection()
        try await connection.connect(to: endpoint)
        opened.append(connection)
        return connection
    }
}

// Samples on every published change instead of spinning: a busy loop on this actor starves
// the wall-clock-bounded tests running beside it.
@MainActor
private final class InvariantWatch {
    private(set) var violations = 0
    private var armed = true

    func watch(_ coordinator: ConnectionCoordinator) {
        withObservationTracking {
            _ = coordinator.phase
            _ = coordinator.browser
        } onChange: { [weak self] in
            // A sampler, not an exhaustive invariant: onChange is nonisolated and fires before the
            // mutation lands, so both the read and the re-arm must hop to the main actor.
            Task { @MainActor in
                guard let self, self.armed else { return }
                if case .connected = coordinator.phase, coordinator.browser == nil {
                    self.violations += 1
                }
                self.watch(coordinator)
            }
        }
    }

    func stop() {
        armed = false
    }
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
        budget: Duration = .seconds(5),
        opener: any ConnectionLaneOpening = KVConnectionLaneOpener(),
        heartbeat: Duration = .seconds(5)
    ) -> ConnectionCoordinator {
        ConnectionCoordinator(
            paths: paths,
            server: server,
            probe: CompatibilityProbe(budget: budget),
            inspector: PortConflictInspector(budget: budget),
            opener: opener,
            heartbeat: heartbeat
        )
    }

    private func compatibleServer() throws -> FakeServer {
        try FakeServer(maxPeers: 8) { peer in FakeKV.serve(peer) }
    }

    private func session(_ endpoint: ConnectionEndpoint) -> ConnectionSession {
        ConnectionSession(target: .existing(endpoint), endpoint: endpoint)
    }

    // MARK: - Existing targets

    @Test func connectingToACompatibleServerReachesConnectedAndOpensBothLanes() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let coordinator = makeCoordinator(paths: paths)

        await coordinator.connect(to: .existing(server.endpoint))

        #expect(coordinator.phase == .connected(session(server.endpoint)))
        try await #require(coordinator.browser).ping()
        try await #require(coordinator.console).ping()
        #expect(coordinator.managedServer == .idle)
        #expect(PreferencesStore(paths: paths).loadLastConnectionTarget() == .existing(server.endpoint))
    }

    @Test func serverThatFailsTheProbeIsRejectedWithItsOutcomeAndIsNotRemembered() async throws {
        let paths = try makePaths()
        let coordinator = makeCoordinator(paths: paths)
        let hostile = try FakeServer(maxPeers: 8) { peer in
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

    // The step a silent peer stalls at depends on load, so this pins the pass-through, not the step.
    @Test func silentPeerIsSurfacedAsTheProbeReportedItWithoutExtraPrecision() async throws {
        let paths = try makePaths()
        let holder = try PortHolder()
        defer { holder.close() }
        let budget = Duration.milliseconds(500)
        let coordinator = makeCoordinator(paths: paths, budget: budget)

        await coordinator.connect(to: .existing(holder.endpoint))

        guard case .failed(let attempt) = coordinator.phase else {
            Issue.record("expected a failed attempt, got \(coordinator.phase)")
            return
        }
        #expect(attempt.target == .existing(holder.endpoint))
        #expect(attempt.failure == .rejected(
            holder.endpoint,
            .unreachable(.timedOut(step: .ping, budget: budget))
        ) || attempt.failure == .rejected(
            holder.endpoint,
            .unreachable(.timedOut(step: nil, budget: budget))
        ))
        #expect(coordinator.browser == nil)
    }

    @Test func browserAndConsoleLanesRunIndependently() async throws {
        let paths = try makePaths()
        let held = Signal()
        let release = DispatchSemaphore(value: 0)
        let server = try FakeServer(maxPeers: 8) { peer in
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

        #expect(coordinator.phase == .connected(session(second.endpoint)))
        await #expect(throws: ConnectionError.notConnected) { try await abandoned.ping() }
        try await #require(coordinator.browser).ping()
    }

    @Test func aFailedSecondLaneLeavesTheFirstLaneClosed() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let opener = SecondLaneFails()
        let coordinator = makeCoordinator(paths: paths, opener: opener)

        await coordinator.connect(to: .existing(server.endpoint))

        #expect(coordinator.phase == .failed(ConnectionAttemptFailure(
            target: .existing(server.endpoint),
            failure: .transport(server.endpoint, .connectFailed("second lane refused"))
        )))
        #expect(coordinator.browser == nil)
        #expect(coordinator.console == nil)
        let stranded = try #require(await opener.opened.first)
        #expect(await stranded.isConnected == false)
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

    @Test func portConflictSurfacesTheOccupantWithoutConnectingToIt() async throws {
        let paths = try makePaths()
        let occupant = try compatibleServer()
        defer { occupant.stop() }
        let host = StubManagedServer(
            endpoint: occupant.endpoint,
            failure: ManagedServerError.portInUse(occupant.endpoint)
        )
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
        let host = StubManagedServer(failure: ManagedServerError.binaryUnavailable(["/nowhere"]))
        let coordinator = makeCoordinator(paths: paths, server: host)

        await coordinator.connect(to: .managedLocal)

        #expect(coordinator.phase == .failed(ConnectionAttemptFailure(
            target: .managedLocal,
            failure: .managedServer(.binaryUnavailable(["/nowhere"]))
        )))
        #expect(coordinator.managedServer == .failed(.binaryUnavailable(["/nowhere"])))
    }

    @Test func anInterruptedStartPublishesAFailureRatherThanSpinning() async throws {
        let paths = try makePaths()
        let host = StubManagedServer(failure: CancellationError())
        let coordinator = makeCoordinator(paths: paths, server: host)

        await coordinator.connect(to: .managedLocal)

        #expect(coordinator.phase == .failed(ConnectionAttemptFailure(
            target: .managedLocal,
            failure: .interrupted
        )))
        #expect(coordinator.managedServer == .idle)
    }

    // MARK: - Restore and reconnect

    @Test func restoringReconnectsTheSavedTarget() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        try PreferencesStore(paths: paths).saveLastConnectionTarget(.existing(server.endpoint))
        let coordinator = makeCoordinator(paths: paths)

        await coordinator.restoreLastConnection()

        #expect(coordinator.phase == .connected(session(server.endpoint)))
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

        #expect(coordinator.phase == .connected(session(server.endpoint)))
        await #expect(throws: ConnectionError.notConnected) { try await first.ping() }
    }

    @Test func reportingALostConnectionDemotesTheConnectedPhaseAndFreesTheLanes() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let coordinator = makeCoordinator(paths: paths)

        await coordinator.connect(to: .existing(server.endpoint))
        let browser = try #require(coordinator.browser)
        await coordinator.reportConnectionLost(.connectionClosed)

        #expect(coordinator.phase == .failed(ConnectionAttemptFailure(
            target: .existing(server.endpoint),
            failure: .transport(server.endpoint, .connectionClosed)
        )))
        #expect(coordinator.browser == nil)
        #expect(coordinator.console == nil)
        await #expect(throws: ConnectionError.notConnected) { try await browser.ping() }

        await coordinator.reconnect()
        #expect(coordinator.phase == .connected(session(server.endpoint)))
    }

    // MARK: - Overlap, cancellation and teardown

    @Test func overlappingConnectsNeverRunTwoAttemptsAtOnce() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let gate = StartLatch()
        let host = StubManagedServer(endpoint: server.endpoint, gate: gate)
        let coordinator = makeCoordinator(paths: paths, server: host)

        let first = Task { await coordinator.connect(to: .managedLocal) }
        await host.waitUntilStarting()
        let second = Task { await coordinator.connect(to: .managedLocal) }
        let third = Task { await coordinator.connect(to: .managedLocal) }
        for _ in 0..<4 { await Task.yield() }
        // Without this the test could pass vacuously: if the later two never reached the attempt
        // machine, "at most one concurrent start" would be true for the wrong reason.
        #expect(await host.startCount == 1)
        gate.open()
        await first.value
        await second.value
        await third.value

        #expect(await host.maxConcurrentStarts == 1)
        #expect(coordinator.phase == .connected(
            ConnectionSession(target: .managedLocal, endpoint: server.endpoint)
        ))
        try await #require(coordinator.browser).ping()
    }

    @Test func phaseNeverClaimsConnectedWithoutLanesWhileSwitchingOrTearingDown() async throws {
        let paths = try makePaths()
        let first = try compatibleServer()
        defer { first.stop() }
        let second = try compatibleServer()
        defer { second.stop() }
        let coordinator = makeCoordinator(paths: paths)
        await coordinator.connect(to: .existing(first.endpoint))

        let watch = InvariantWatch()
        watch.watch(coordinator)

        await coordinator.connect(to: .existing(second.endpoint))
        await coordinator.shutDown()
        watch.stop()

        #expect(watch.violations == 0)
        #expect(coordinator.phase == .disconnected)
    }

    @Test func shuttingDownDuringAStartDoesNotWaitForTheStartToFinish() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let gate = StartLatch()
        let host = StubManagedServer(endpoint: server.endpoint, gate: gate)
        let coordinator = makeCoordinator(paths: paths, server: host)

        let connecting = Task { await coordinator.connect(to: .managedLocal) }
        await host.waitUntilStarting()

        // Deadlocks until the time limit if teardown waits out a start only stop() can end.
        await coordinator.shutDown()
        await connecting.value

        #expect(coordinator.phase == .disconnected)
        #expect(coordinator.browser == nil)
        #expect(coordinator.console == nil)
        #expect(await host.stopCount == 1)
        #expect(server.acceptedCount == 0)
    }

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

    @Test func aStopThatLeavesALiveProcessIsSurfacedAsUnreclaimed() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let host = StubManagedServer(endpoint: server.endpoint, stopOutcome: .unreclaimed(777))
        let coordinator = makeCoordinator(paths: paths, server: host)

        await coordinator.connect(to: .managedLocal)
        await coordinator.shutDown()

        #expect(coordinator.managedServer == .unreclaimed(777))
        #expect(coordinator.phase == .disconnected)
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

    @Test func shuttingDownFromAFailedAttemptIsQuiet() async throws {
        let paths = try makePaths()
        let holder = try PortHolder()
        defer { holder.close() }
        let host = StubManagedServer()
        let coordinator = makeCoordinator(paths: paths, server: host, budget: .milliseconds(200))

        await coordinator.connect(to: .existing(holder.endpoint))
        await coordinator.shutDown()

        #expect(coordinator.phase == .disconnected)
        #expect(await host.stopCount == 0)
    }

    @Test func connectingAfterShutDownIsRefused() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let host = StubManagedServer(endpoint: server.endpoint)
        let coordinator = makeCoordinator(paths: paths, server: host)

        await coordinator.shutDown()
        await coordinator.connect(to: .managedLocal)

        #expect(coordinator.phase == .disconnected)
        #expect(coordinator.browser == nil)
        #expect(await host.startCount == 0)
        #expect(server.acceptedCount == 0)
    }

    @Test func cancellingTheDrivingTaskStillLeavesPhaseAndLanesAgreeing() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let coordinator = makeCoordinator(paths: paths)

        let driver = Task { await coordinator.connect(to: .existing(server.endpoint)) }
        driver.cancel()
        await driver.value

        #expect(coordinator.phase == .connected(session(server.endpoint)))
        try await #require(coordinator.browser).ping()
        try await #require(coordinator.console).ping()
    }

    // MARK: - Reopening

    @Test func restoringTheLastConnectionObeysTheReopenPreference() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let store = PreferencesStore(paths: paths)
        try store.saveLastConnectionTarget(.existing(server.endpoint))

        var preferences = store.loadPreferences()
        preferences.reopenLastConnection = false
        try store.savePreferences(preferences)
        let declining = makeCoordinator(paths: paths)
        await declining.restoreLastConnection()
        #expect(declining.phase == .disconnected)
        #expect(server.acceptedCount == 0)

        preferences.reopenLastConnection = true
        try store.savePreferences(preferences)
        let accepting = makeCoordinator(paths: paths)
        await accepting.restoreLastConnection()
        #expect(accepting.phase == .connected(session(server.endpoint)))
    }

    // MARK: - Liveness

    @Test func aServerThatDiesIsNoticedWithNothingBeingAsked() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        let coordinator = makeCoordinator(paths: paths, heartbeat: .milliseconds(50))

        await coordinator.connect(to: .existing(server.endpoint))
        try #require(coordinator.phase == .connected(session(server.endpoint)))

        server.stop()

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if case .failed = coordinator.phase { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        guard case .failed = coordinator.phase else {
            Issue.record("still reporting a connection to a server that is gone")
            return
        }
        #expect(coordinator.browser == nil)
        #expect(coordinator.console == nil)
    }

    @Test func theHeartbeatStopsWhenTheConnectionDoes() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        let coordinator = makeCoordinator(paths: paths, heartbeat: .milliseconds(50))

        await coordinator.connect(to: .existing(server.endpoint))
        await coordinator.disconnect()
        server.stop()

        // A heartbeat that outlives its connection would turn a deliberate disconnect into a failure.
        try await Task.sleep(for: .milliseconds(400))
        #expect(coordinator.phase == .disconnected)
    }

    @Test func theHeartbeatLeavesAHealthyConnectionAlone() async throws {
        let paths = try makePaths()
        let server = try compatibleServer()
        defer { server.stop() }
        let coordinator = makeCoordinator(paths: paths, heartbeat: .milliseconds(50))

        await coordinator.connect(to: .existing(server.endpoint))
        try await Task.sleep(for: .milliseconds(400))

        #expect(coordinator.phase == .connected(session(server.endpoint)))
        try await #require(coordinator.browser).ping()
    }
}
