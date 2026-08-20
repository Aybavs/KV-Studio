import Foundation

protocol ReleaseMetadataFetching: Sendable {
    func fetchLatestRelease() async throws -> Data
}

// Metadata only. Nothing here downloads or runs an archive; verification comes first.
struct BackendReleaseLookup: Sendable {
    let fetcher: any ReleaseMetadataFetching
    let architecture: HostArchitecture

    init(fetcher: any ReleaseMetadataFetching = GitHubReleaseFetcher(), architecture: HostArchitecture = .current) {
        self.fetcher = fetcher
        self.architecture = architecture
    }

    func latest() async throws -> BackendRelease {
        let payload = try await fetcher.fetchLatestRelease()

        guard let listing = try? JSONDecoder().decode(ReleaseListing.self, from: payload) else {
            throw BackendReleaseError.unreadableResponse
        }
        guard let version = SemanticVersion(string: listing.tagName) else {
            throw BackendReleaseError.unusableVersion(listing.tagName)
        }

        let suffix = "\(architecture.assetSuffix).tar.gz"
        guard let archive = listing.assets.first(where: { $0.name.hasSuffix(suffix) }) else {
            throw BackendReleaseError.missingArchive(architecture.assetSuffix)
        }
        guard let checksums = listing.assets.first(where: { $0.name == "SHA256SUMS" }) else {
            throw BackendReleaseError.missingChecksums
        }

        return BackendRelease(version: version, archive: archive.asset, checksums: checksums.asset)
    }
}

private struct ReleaseListing: Decodable {
    let tagName: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let size: Int
        let browserDownloadURL: URL

        var asset: BackendReleaseAsset {
            BackendReleaseAsset(name: name, url: browserDownloadURL, size: size)
        }

        private enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

struct GitHubReleaseFetcher: ReleaseMetadataFetching {
    // GitHub's /latest excludes drafts and prereleases, which is exactly the v0.1 policy.
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/Aybavs/go-kv-store/releases/latest")!

    let url: URL
    let session: URLSession

    init(url: URL = GitHubReleaseFetcher.latestReleaseURL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    func fetchLatestRelease() async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        return data
    }
}
