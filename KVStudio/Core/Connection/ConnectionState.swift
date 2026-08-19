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

protocol ManagedServerHosting: Sendable {
    func start() async throws -> pid_t
    func stop() async
    var endpoint: ConnectionEndpoint? { get async }
}

extension ManagedServerController: ManagedServerHosting {}
