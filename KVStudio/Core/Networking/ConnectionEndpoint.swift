import Foundation

struct ConnectionEndpoint: Equatable, Hashable, Sendable {
    let host: String
    let port: UInt16

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}
