import Foundation

enum LogsAvailability {
    static func isManaged(phase: ConnectionPhase) -> Bool {
        switch phase {
        case .connected(let session): return session.target == .managedLocal
        case .connecting(let target): return target == .managedLocal
        case .failed(let attempt): return attempt.target == .managedLocal
        case .disconnected: return true
        }
    }
}
