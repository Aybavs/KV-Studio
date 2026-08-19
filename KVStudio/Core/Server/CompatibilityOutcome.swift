import Foundation

enum ProbeStep: Equatable, Sendable {
    case ping
    case dbSize
    case scan
}

// go-kv-store prefixes every error with a stable class; the wording after it is not stable.
enum ServerErrorClass: CaseIterable, Equatable, Sendable {
    case unknownCommand
    case wrongArgumentCount
    case invalidCursor
    case scanMatchChanged
    case scanSessionLimit
    case shuttingDown
    case maxClients
    case syntaxError
    case protocolError

    var prefix: String {
        switch self {
        case .unknownCommand: return "ERR unknown command '"
        case .wrongArgumentCount: return "ERR wrong number of arguments for '"
        case .invalidCursor: return "ERR invalid cursor"
        case .scanMatchChanged: return "ERR scan MATCH cannot change during iteration"
        case .scanSessionLimit: return "ERR scan session limit reached"
        case .shuttingDown: return "ERR server is shutting down"
        case .maxClients: return "ERR max number of clients reached"
        case .syntaxError: return "ERR syntax error"
        case .protocolError: return "ERR Protocol error:"
        }
    }

    init?(message: String) {
        guard let match = Self.allCases.first(where: { message.hasPrefix($0.prefix) }) else { return nil }
        self = match
    }
}

enum UnreachableReason: Equatable, Sendable {
    case invalidPort(UInt16)
    case connectFailed(String)
    case timedOut(Duration)
}

enum IncompatibilityReason: Equatable, Sendable {
    case serverError(class: ServerErrorClass?, message: String)
    case unexpectedReply(RESPValue)
}

enum ProtocolFailureReason: Equatable, Sendable {
    case malformedReply(RESPError)
    case connectionClosed
    case transportFailure(String)
    case timedOut(Duration)
}

enum CompatibilityOutcome: Equatable, Sendable {
    case compatible
    case unreachable(UnreachableReason)
    case incompatible(step: ProbeStep, reason: IncompatibilityReason)
    case protocolFailure(step: ProbeStep, reason: ProtocolFailureReason)
}
