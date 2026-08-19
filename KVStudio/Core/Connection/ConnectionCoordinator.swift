import Foundation
import Observation

@MainActor
@Observable
final class ConnectionCoordinator {

    private(set) var phase: ConnectionPhase = .disconnected
    private(set) var managedServer: ManagedServerStatus = .idle
    // Two connections, not one: KVConnection serializes commands, so a Browser traversal
    // would otherwise sit in front of every Console command.
    private(set) var browser: KVClient?
    private(set) var console: KVClient?

    @ObservationIgnored private let preferences: PreferencesStore
    @ObservationIgnored private let server: any ManagedServerHosting
    @ObservationIgnored private let probe: CompatibilityProbe
    @ObservationIgnored private let inspector: PortConflictInspector
    @ObservationIgnored private let opener: any ConnectionLaneOpening

    @ObservationIgnored private var browserConnection: KVConnection?
    @ObservationIgnored private var consoleConnection: KVConnection?
    @ObservationIgnored private var attempt: Task<Void, Never>?
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var ownsManagedServer = false
    @ObservationIgnored private var lastTarget: ConnectionTarget?

    init(
        paths: ManagedPaths,
        server: any ManagedServerHosting,
        probe: CompatibilityProbe = CompatibilityProbe(),
        inspector: PortConflictInspector = PortConflictInspector(),
        opener: any ConnectionLaneOpening = KVConnectionLaneOpener()
    ) {
        self.preferences = PreferencesStore(paths: paths)
        self.server = server
        self.probe = probe
        self.inspector = inspector
        self.opener = opener
    }

    convenience init(paths: ManagedPaths) {
        self.init(paths: paths, server: ManagedServerHost(paths: paths))
    }

    // MARK: - Connecting

    func connect(to target: ConnectionTarget) async {
        guard !isShuttingDown else { return }
        await cancelAttempt()
        guard !isShuttingDown else { return }

        let task = Task { await self.attemptConnection(to: target) }
        attempt = task
        await task.value
        if attempt == task { attempt = nil }
    }

    func reconnect() async {
        guard let target = lastTarget ?? preferences.loadLastConnectionTarget() else { return }
        await connect(to: target)
    }

    func restoreLastConnection() async {
        guard let target = preferences.loadLastConnectionTarget() else { return }
        await connect(to: target)
    }

    // The shell calls this when a command comes back .notConnected or .connectionClosed;
    // detecting a dead peer is not this task's job, reacting to the report is.
    func reportConnectionLost(_ error: ConnectionError) async {
        guard !isShuttingDown, case .connected(let session) = phase else { return }
        phase = .failed(ConnectionAttemptFailure(
            target: session.target,
            failure: .transport(session.endpoint, error)
        ))
        await closeLanes()
    }

    func shutDown() async {
        isShuttingDown = true
        // ManagedServerController.stop() cancels a live start from the inside; awaiting the
        // attempt first would throw that away and wait out a start nobody else can cancel.
        let stopping = ownsManagedServer ? beginStop() : nil

        await cancelAttempt()
        phase = .disconnected
        await closeLanes()

        guard let stopping else { return }
        let outcome = await stopping.value
        ownsManagedServer = false
        managedServer = Self.status(for: outcome)
    }

    // MARK: - Attempts

    // Every exit from here either publishes a phase or is superseded; never both, never neither.
    private func attemptConnection(to target: ConnectionTarget) async {
        guard isLive else { return }
        lastTarget = target
        // Before the lanes are closed, so the phase never outlives the lanes it describes.
        phase = .connecting(target)
        await closeLanes()
        guard isLive else { return }

        let reached: ConnectionEndpoint?
        switch target {
        case .existing(let candidate):
            reached = await accept(candidate)
        case .managedLocal:
            reached = await startManagedServer()
        }
        guard let endpoint = reached, isLive else { return }

        do {
            try await openLanes(to: endpoint)
        } catch {
            await closeLanes()
            publish(.failed(ConnectionAttemptFailure(
                target: target,
                failure: .transport(endpoint, Self.connectionError(error))
            )))
            return
        }

        guard isLive else {
            await closeLanes()
            return
        }
        try? preferences.saveLastConnectionTarget(target)
        publish(.connected(ConnectionSession(target: target, endpoint: endpoint)))
    }

    // A server that connects but fails the probe never becomes the active connection.
    private func accept(_ endpoint: ConnectionEndpoint) async -> ConnectionEndpoint? {
        let outcome: CompatibilityOutcome
        do {
            outcome = try await probe.run(against: endpoint)
        } catch {
            publish(.failed(ConnectionAttemptFailure(target: .existing(endpoint), failure: .interrupted)))
            return nil
        }
        guard outcome == .compatible else {
            publish(.failed(ConnectionAttemptFailure(
                target: .existing(endpoint),
                failure: .rejected(endpoint, outcome)
            )))
            return nil
        }
        return endpoint
    }

    private func startManagedServer() async -> ConnectionEndpoint? {
        managedServer = .starting
        // Claimed before the call: a start that fails or is abandoned half-way still leaves a
        // backend for shutDown to stop.
        ownsManagedServer = true

        let handle: ManagedServerHandle
        do {
            handle = try await server.start()
        } catch let error as ManagedServerError {
            managedServer = .failed(error)
            publish(.failed(ConnectionAttemptFailure(
                target: .managedLocal,
                failure: await failure(for: error)
            )))
            return nil
        } catch {
            managedServer = .idle
            publish(.failed(ConnectionAttemptFailure(target: .managedLocal, failure: .interrupted)))
            return nil
        }

        guard isLive else { return nil }
        managedServer = .running(handle.pid)
        return handle.endpoint
    }

    private func failure(for error: ManagedServerError) async -> ConnectionFailure {
        guard case .portInUse(let endpoint) = error,
              let occupancy = try? await inspector.inspect(endpoint) else {
            return .managedServer(error)
        }
        return .portConflict(occupancy)
    }

    // MARK: - Serialization

    private var isLive: Bool { !Task.isCancelled && !isShuttingDown }

    // Only clears the slot it awaited: a caller that parked behind an older attempt must not
    // erase the registration of the attempt that replaced it.
    private func cancelAttempt() async {
        while let current = attempt {
            current.cancel()
            await current.value
            if attempt == current { attempt = nil }
        }
    }

    private func publish(_ next: ConnectionPhase) {
        guard isLive else { return }
        phase = next
    }

    private func beginStop() -> Task<ManagedServerStopOutcome, Never> {
        managedServer = .stopping
        return Task { await self.server.stop() }
    }

    // MARK: - Lanes

    private func openLanes(to endpoint: ConnectionEndpoint) async throws {
        let browserConnection = try await opener.open(to: endpoint)
        let consoleConnection: KVConnection
        do {
            consoleConnection = try await opener.open(to: endpoint)
        } catch {
            await browserConnection.disconnect()
            throw error
        }

        self.browserConnection = browserConnection
        self.consoleConnection = consoleConnection
        browser = KVClient(connection: browserConnection)
        console = KVClient(connection: consoleConnection)
    }

    private func closeLanes() async {
        let open = [browserConnection, consoleConnection].compactMap { $0 }
        browserConnection = nil
        consoleConnection = nil
        browser = nil
        console = nil
        for connection in open { await connection.disconnect() }
    }

    private static func status(for outcome: ManagedServerStopOutcome) -> ManagedServerStatus {
        switch outcome {
        case .stopped: return .stopped
        case .unreclaimed(let pid): return .unreclaimed(pid)
        }
    }

    private static func connectionError(_ error: any Error) -> ConnectionError {
        (error as? ConnectionError) ?? .connectFailed(String(describing: error))
    }
}
