import Foundation

enum ConnectionTarget: Equatable, Sendable {
    case managedLocal
    case existing(ConnectionEndpoint)
}

extension ConnectionTarget: Codable {
    private enum Kind: String, Codable {
        case managedLocal
        case existing
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case host
        case port
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .managedLocal:
            self = .managedLocal
        case .existing:
            let host = try container.decode(String.self, forKey: .host)
            let port = try container.decode(UInt16.self, forKey: .port)
            self = .existing(ConnectionEndpoint(host: host, port: port))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .managedLocal:
            try container.encode(Kind.managedLocal, forKey: .kind)
        case .existing(let endpoint):
            try container.encode(Kind.existing, forKey: .kind)
            try container.encode(endpoint.host, forKey: .host)
            try container.encode(endpoint.port, forKey: .port)
        }
    }
}
