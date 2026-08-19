import Darwin
import Foundation

struct ConnectionSession: Equatable, Sendable {
    let target: ConnectionTarget
    let endpoint: ConnectionEndpoint
}

enum ConnectionFailure: Equatable, Sendable {
    // The probe's verdict, verbatim: it is the only thing that knows how far it got.
    case rejected(ConnectionEndpoint, CompatibilityOutcome)
    case portConflict(PortOccupancy)
    case managedServer(ManagedServerError)
    case transport(ConnectionEndpoint, ConnectionError)
    case interrupted
}

struct ConnectionAttemptFailure: Equatable, Sendable {
    let target: ConnectionTarget
    let failure: ConnectionFailure
}

enum ConnectionPhase: Equatable, Sendable {
    case disconnected
    case connecting(ConnectionTarget)
    case connected(ConnectionSession)
    case failed(ConnectionAttemptFailure)
}

// What this coordinator knows about the managed backend from its own start/stop calls.
enum ManagedServerStatus: Equatable, Sendable {
    case idle
    case starting
    case running(pid_t)
    case stopping
    case stopped
    case unreclaimed(pid_t)
    case failed(ManagedServerError)
}

struct ManagedServerHandle: Equatable, Sendable {
    let pid: pid_t
    let endpoint: ConnectionEndpoint
}

enum ManagedServerStopOutcome: Equatable, Sendable {
    case stopped
    case unreclaimed(pid_t)
}

protocol ManagedServerHosting: Sendable {
    func start() async throws -> ManagedServerHandle
    func stop() async -> ManagedServerStopOutcome
}

protocol ConnectionLaneOpening: Sendable {
    func open(to endpoint: ConnectionEndpoint) async throws -> KVConnection
}

struct KVConnectionLaneOpener: ConnectionLaneOpening {
    func open(to endpoint: ConnectionEndpoint) async throws -> KVConnection {
        let connection = KVConnection()
        try await connection.connect(to: endpoint)
        return connection
    }
}
