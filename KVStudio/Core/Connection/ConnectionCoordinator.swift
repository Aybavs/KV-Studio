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
    @ObservationIgnored private let records: ManagedServerRecordStore
    @ObservationIgnored private let server: any ManagedServerHosting
    @ObservationIgnored private let probe: CompatibilityProbe
    @ObservationIgnored private let inspector: PortConflictInspector

    @ObservationIgnored private var browserConnection: KVConnection?
    @ObservationIgnored private var consoleConnection: KVConnection?
    @ObservationIgnored private var attempt: Task<Void, Never>?
    @ObservationIgnored private var ownsManagedServer = false
    @ObservationIgnored private var lastTarget: ConnectionTarget?

    init(
        paths: ManagedPaths,
        server: any ManagedServerHosting,
        probe: CompatibilityProbe = CompatibilityProbe(),
        inspector: PortConflictInspector = PortConflictInspector()
    ) {
        self.preferences = PreferencesStore(paths: paths)
        self.records = ManagedServerRecordStore(paths: paths)
        self.server = server
        self.probe = probe
        self.inspector = inspector
    }

    convenience init(paths: ManagedPaths) {
        self.init(paths: paths, server: ManagedServerController(paths: paths))
    }

    // MARK: - Connecting

    func connect(to target: ConnectionTarget) async {
        await supersedeAttempt()
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

    func shutDown() async {
        await supersedeAttempt()
        await closeLanes()
        phase = .disconnected

        guard ownsManagedServer else { return }
        ownsManagedServer = false
        managedServer = .stopping
        await server.stop()
        managedServer = stoppedStatus()
    }

    // MARK: - Attempts

    private func attemptConnection(to target: ConnectionTarget) async {
        lastTarget = target
        await closeLanes()
        phase = .connecting(target)

        let endpoint: ConnectionEndpoint?
        switch target {
        case .existing(let candidate):
            endpoint = await accept(candidate)
        case .managedLocal:
            endpoint = await startManagedServer()
        }
        guard let endpoint else { return }

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

        try? preferences.saveLastConnectionTarget(target)
        publish(.connected(ConnectionSession(target: target, endpoint: endpoint)))
    }

    // A server that connects but fails the probe never becomes the active connection.
    private func accept(_ endpoint: ConnectionEndpoint) async -> ConnectionEndpoint? {
        guard let outcome = try? await probe.run(against: endpoint) else { return nil }
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
        do {
            let pid = try await server.start()
            ownsManagedServer = true
            managedServer = .running(pid)
            return await server.endpoint ?? localEndpoint()
        } catch let error as ManagedServerError {
            managedServer = .failed(error)
            publish(.failed(ConnectionAttemptFailure(
                target: .managedLocal,
                failure: await failure(for: error)
            )))
            return nil
        } catch {
            return nil
        }
    }

    // Offering the occupant is the onboarding screen's call, and accepting it is the user's.
    private func failure(for error: ManagedServerError) async -> ConnectionFailure {
        guard case .portInUse(let endpoint) = error,
              let occupancy = try? await inspector.inspect(endpoint) else {
            return .managedServer(error)
        }
        return .portConflict(occupancy)
    }

    private func localEndpoint() -> ConnectionEndpoint {
        let settings = preferences.loadPreferences()
        return ConnectionEndpoint(host: settings.localBindHost, port: settings.localPort)
    }

    private func supersedeAttempt() async {
        guard let attempt else { return }
        attempt.cancel()
        await attempt.value
        self.attempt = nil
    }

    private func publish(_ next: ConnectionPhase) {
        guard !Task.isCancelled else { return }
        phase = next
    }

    // MARK: - Lanes

    private func openLanes(to endpoint: ConnectionEndpoint) async throws {
        let browserConnection = KVConnection()
        try await browserConnection.connect(to: endpoint)

        let consoleConnection = KVConnection()
        do {
            try await consoleConnection.connect(to: endpoint)
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

    // The controller reports `.stopped` even when it deliberately preserved a record for a
    // process it could not kill; the record is what says whether that process outlived the stop.
    private func stoppedStatus() -> ManagedServerStatus {
        guard let record = records.load(), record.identifiesLiveProcess, let pid = record.pid else {
            return .stopped
        }
        return .unreclaimed(pid)
    }

    private static func connectionError(_ error: any Error) -> ConnectionError {
        (error as? ConnectionError) ?? .connectFailed(String(describing: error))
    }
}
