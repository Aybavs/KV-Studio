import Foundation

enum ManagedServerError: Error, Equatable, Sendable {
    case binaryUnavailable([String])
    case storageUnavailable(String)
    case launchFailed(String)
    case exitedDuringStartup(Int32)
    case readinessTimedOut(ConnectionEndpoint, Duration)
    case portInUse(ConnectionEndpoint)
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
        }
    }
}
