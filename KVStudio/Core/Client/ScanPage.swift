import Foundation

struct ScanPage: Equatable, Sendable {
    let nextCursor: UInt64
    let keys: [Data]
}

enum SetExpiration: Equatable, Sendable {
    case seconds(Int64)
    case milliseconds(Int64)
}
