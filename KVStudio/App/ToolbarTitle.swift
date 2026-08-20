import Foundation

func toolbarTitle(for phase: ConnectionPhase) -> String {
    switch phase {
    case .disconnected:
        return "Disconnected"
    case .connecting(let target):
        switch target {
        case .managedLocal: return "Connecting to Local Server…"
        case .existing(let endpoint): return "Connecting to \(endpoint.host):\(endpoint.port)…"
        }
    case .connected(let session):
        return "Connected to \(session.endpoint.host):\(session.endpoint.port)"
    case .failed(let attempt):
        switch attempt.failure {
        case .rejected(_, let outcome):
            switch outcome {
            case .compatible: return "Server rejected"
            case .unreachable: return "Server unreachable"
            case .incompatible: return "Incompatible server"
            case .protocolFailure: return "Protocol error"
            }
        case .portConflict(let occupancy):
            return "Port \(occupancy.endpoint.port) in use"
        case .managedServer(let error):
            return error.localizedDescription
        case .transport(_, let error):
            return error.localizedDescription
        case .interrupted:
            return "Connection interrupted"
        }
    }
}
