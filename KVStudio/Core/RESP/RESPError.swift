import Foundation

/// A RESP2 protocol violation. Fatal for the connection: the stream offset is no longer known.
enum RESPError: Error, Equatable, Sendable {
    case unknownTypeByte(UInt8)
    case invalidInteger
    case invalidLength
    case invalidTerminator
    case nestingTooDeep
}

extension RESPError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unknownTypeByte(let byte):
            let printable = (0x20...0x7E).contains(byte)
                ? "'\(Character(UnicodeScalar(byte)))'"
                : String(format: "0x%02X", byte)
            return "Unexpected RESP type byte \(printable)."
        case .invalidInteger:
            return "The server sent a malformed number."
        case .invalidLength:
            return "The server sent a malformed length prefix."
        case .invalidTerminator:
            return "The server sent a reply that was not terminated correctly."
        case .nestingTooDeep:
            return "The server sent a reply nested too deeply to decode."
        }
    }
}
