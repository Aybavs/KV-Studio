import Foundation

/// A RESP2 protocol value. `Data` throughout, never `String`, so arbitrary bytes round-trip.
enum RESPValue: Equatable, Sendable {
    case simpleString(Data)
    case error(Data)
    case integer(Int64)
    case bulkString(Data?)
    case array([RESPValue]?)
}
