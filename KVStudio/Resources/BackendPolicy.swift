import Foundation

struct BackendPolicy: Codable, Equatable, Sendable {
    var schema: Int
    var minimumBackend: String
    var bundledBackend: String
    var recommendedBackend: String

    static let fallback = BackendPolicy(schema: 1, minimumBackend: "1.1.0", bundledBackend: "1.1.0", recommendedBackend: "1.1.0")

    static func load(from url: URL?) -> BackendPolicy {
        guard let url, let data = try? Data(contentsOf: url) else { return .fallback }
        guard let decoded = try? JSONDecoder().decode(BackendPolicy.self, from: data) else { return .fallback }
        guard decoded.schema == 1,
              !decoded.minimumBackend.isEmpty,
              !decoded.bundledBackend.isEmpty,
              !decoded.recommendedBackend.isEmpty else { return .fallback }
        return decoded
    }

    static func loadFromBundle(bundle: Bundle = .main) -> BackendPolicy {
        let url = bundle.url(forResource: "BackendPolicy", withExtension: "json")
        return load(from: url)
    }
}
