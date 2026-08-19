import Darwin
import Foundation

enum ManagedServerError: Error, Equatable, Sendable {
    case binaryUnavailable([String])
    case storageUnavailable(String)
    case launchFailed(String)
    case exitedDuringStartup(Int32)
    case readinessTimedOut(ConnectionEndpoint, Duration)
    case portInUse(ConnectionEndpoint)
    case terminationFailed(pid_t)
    case unreclaimedServer(ConnectionEndpoint)
}

extension ManagedServerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .binaryUnavailable(let checked):
            let locations = checked.isEmpty ? "no candidate locations" : checked.joined(separator: ", ")
            return "No kv-server binary is available. Checked: \(locations). "
                + "Install a managed backend or set \(ServerBinaryResolver.overrideEnvironmentKey)."
        case .storageUnavailable(let detail):
            return "Could not prepare the managed server's files: \(detail)"
        case .launchFailed(let detail):
            return "Could not launch kv-server: \(detail)"
        case .exitedDuringStartup(let status):
            return "kv-server exited with status \(status) before it accepted connections. "
                + "Check the server log for details."
        case .readinessTimedOut(let endpoint, let budget):
            return "kv-server did not answer PING on \(endpoint.host):\(endpoint.port) "
                + "within \(budget). The server was stopped."
        case .portInUse(let endpoint):
            return "Port \(endpoint.port) on \(endpoint.host) is already in use by another process. "
                + "Stop that process or choose a different port."
        case .terminationFailed(let pid):
            return "kv-server (pid \(pid)) did not exit after being killed. Studio kept its record so it "
                + "can reclaim the process later; you may need to end it yourself."
        case .unreclaimedServer(let endpoint):
            return "Studio started a kv-server on \(endpoint.host):\(endpoint.port) but lost track of it, "
                + "and cannot prove which process now holds that port. Stop it yourself, or choose a "
                + "different port."
        }
    }
}
