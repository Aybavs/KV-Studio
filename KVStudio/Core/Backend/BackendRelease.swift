import Foundation

struct BackendReleaseAsset: Equatable, Sendable {
    let name: String
    let url: URL
    let size: Int
}

struct BackendRelease: Equatable, Sendable {
    let version: SemanticVersion
    let archive: BackendReleaseAsset
    let checksums: BackendReleaseAsset
}

enum BackendReleaseError: Error, Equatable {
    case unreadableResponse
    case unusableVersion(String)
    case missingArchive(String)
    case missingChecksums
}

extension BackendReleaseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unreadableResponse:
            return "The release listing could not be read."
        case .unusableVersion(let tag):
            return "Release “\(tag)” is not a version KV Studio can compare."
        case .missingArchive(let platform):
            return "The latest release has no \(platform) build."
        case .missingChecksums:
            return "The latest release has no SHA256SUMS file."
        }
    }
}
