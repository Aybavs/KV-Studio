import Foundation

// GNU coreutils shape: "<64 hex>  <filename>", which is what the release publishes.
struct ChecksumManifest: Equatable, Sendable {
    private let digests: [String: String]

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw BackendStagingError.checksumsUnreadable
        }

        var parsed: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { throw BackendStagingError.checksumsUnreadable }

            let digest = parts[0].lowercased()
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
                throw BackendStagingError.checksumsUnreadable
            }

            let name = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw BackendStagingError.checksumsUnreadable }
            parsed[name] = digest
        }

        guard !parsed.isEmpty else { throw BackendStagingError.checksumsUnreadable }
        digests = parsed
    }

    func digest(for filename: String) -> String? { digests[filename] }
}
