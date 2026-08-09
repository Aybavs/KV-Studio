import Foundation

/// A RESP2 protocol value.
///
/// Values are binary-safe: `Data` is used throughout instead of `String` so that
/// keys and values containing NUL bytes, CRLF, or invalid UTF-8 round-trip exactly.
///
/// This type only exists as the shared vocabulary the encoder and decoder speak;
/// encoding and decoding RESP2 bytes into this type live elsewhere.
enum RESPValue: Equatable, Sendable {
    case simpleString(Data)
    case error(Data)
    case integer(Int64)
    case bulkString(Data?)
    case array([RESPValue]?)
}
