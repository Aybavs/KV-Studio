import Foundation

/// Encodes outgoing commands as RESP2 "array of bulk strings" frames — the only
/// request shape a RESP2 client ever needs to send.
enum RESPEncoder {
    private static let crlf: [UInt8] = [0x0D, 0x0A] // "\r\n"

    /// Encodes `arguments` as a RESP2 command: `*<count>\r\n` followed by one
    /// `$<byte length>\r\n<bytes>\r\n` bulk string per argument, in order.
    ///
    /// Arguments are treated as opaque bytes — the length prefix always counts
    /// bytes, never characters, so multi-byte UTF-8 and arbitrary binary data
    /// (including embedded NUL bytes or CRLF) encode correctly.
    static func encodeCommand(_ arguments: [Data]) -> Data {
        var bytes: [UInt8] = Array("*\(arguments.count)\r\n".utf8)
        bytes.reserveCapacity(bytes.count + arguments.reduce(0) { $0 + $1.count + 16 })

        for argument in arguments {
            bytes += Array("$\(argument.count)\r\n".utf8)
            bytes += argument
            bytes += crlf
        }

        return Data(bytes)
    }
}
