import Foundation

// Transport failures only; a `-ERR` reply is a RESPValue.
enum ConnectionError: Error, Equatable, Sendable {
    case notConnected
    case invalidPort(UInt16)
    case connectFailed(String)
    case connectionClosed
    case transportFailure(String)
    case protocolViolation(RESPError)
}

extension ConnectionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to a server."
        case .invalidPort(let port):
            return "Port \(port) is not a valid TCP port."
        case .connectFailed(let detail):
            return "Could not connect: \(detail)"
        case .connectionClosed:
            return "The server closed the connection."
        case .transportFailure(let detail):
            return "The connection failed: \(detail)"
        case .protocolViolation(let error):
            return error.errorDescription
        }
    }
}
