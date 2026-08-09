import Foundation

/// A RESP2 protocol violation: the bytes on the wire cannot be interpreted as a reply.
///
/// These are *fatal for the connection*. Once the stream contains a byte the decoder
/// cannot make sense of, every subsequent byte is at an unknown offset, so there is no
/// safe way to resynchronise — the caller must tear the connection down.
///
/// A reply that has simply not arrived in full is **not** an error: the decoder reports
/// that by returning `nil` from `nextValue()` and waits for more bytes.
enum RESPError: Error, Equatable, Sendable {
    /// The reply started with a byte that is not one of `+ - : $ *`.
    case unknownTypeByte(UInt8)

    /// A line that should hold a number held something else, or a number too large for `Int64`.
    case invalidInteger

    /// A bulk-string or array length was negative (other than the `-1` null marker)
    /// or larger than the decoder is willing to buffer.
    case invalidLength

    /// A frame was not terminated by CRLF where the protocol requires one.
    case invalidTerminator

    /// Arrays were nested more deeply than the decoder will recurse.
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
