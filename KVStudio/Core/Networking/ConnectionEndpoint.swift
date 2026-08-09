import Foundation

struct ConnectionEndpoint: Equatable, Hashable, Sendable {
    let host: String
    let port: UInt16
}
