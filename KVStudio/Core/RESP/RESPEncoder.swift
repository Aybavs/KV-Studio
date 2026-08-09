import Foundation

/// Encodes commands as RESP2 arrays of bulk strings. Length prefixes count bytes, not characters.
enum RESPEncoder {
    private static let crlf: [UInt8] = [0x0D, 0x0A]

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
