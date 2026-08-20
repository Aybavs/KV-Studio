import Foundation
import Testing
@testable import KV_Studio

private struct StubFetcher: ReleaseMetadataFetching {
    let payload: Result<Data, any Error>

    init(_ json: String) { payload = .success(Data(json.utf8)) }
    init(failing error: any Error) { payload = .failure(error) }

    func fetchLatestRelease() async throws -> Data { try payload.get() }
}

private enum StubError: Error { case offline }

private func releaseJSON(
    tag: String = "v1.1.0",
    assets: [String] = [
        "kv-server_v1.1.0_darwin_arm64.tar.gz",
        "kv-server_v1.1.0_darwin_amd64.tar.gz",
        "kv-server_v1.1.0_linux_arm64.tar.gz",
        "SHA256SUMS"
    ]
) -> String {
    let entries = assets.map { name in
        """
        {"name":"\(name)","size":1234,"browser_download_url":"https://example.invalid/\(name)"}
        """
    }.joined(separator: ",")
    return #"{"tag_name":"\#(tag)","assets":[\#(entries)]}"#
}

@Suite
struct BackendReleaseLookupTests {

    @Test func picksTheArm64ArchiveOnAppleSilicon() async throws {
        let lookup = BackendReleaseLookup(fetcher: StubFetcher(releaseJSON()), architecture: .arm64)

        let release = try await lookup.latest()

        #expect(release.version == SemanticVersion(string: "1.1.0"))
        #expect(release.archive.name == "kv-server_v1.1.0_darwin_arm64.tar.gz")
        #expect(release.checksums.name == "SHA256SUMS")
    }

    @Test func picksTheAmd64ArchiveOnIntel() async throws {
        let lookup = BackendReleaseLookup(fetcher: StubFetcher(releaseJSON()), architecture: .amd64)

        let release = try await lookup.latest()

        #expect(release.archive.name == "kv-server_v1.1.0_darwin_amd64.tar.gz")
    }

    @Test func neverSelectsALinuxArchive() async throws {
        let json = releaseJSON(assets: ["kv-server_v1.1.0_linux_arm64.tar.gz", "SHA256SUMS"])
        let lookup = BackendReleaseLookup(fetcher: StubFetcher(json), architecture: .arm64)

        await #expect(throws: BackendReleaseError.self) { try await lookup.latest() }
    }

    @Test func reportsAMissingArchiveForThisArchitecture() async throws {
        let json = releaseJSON(assets: ["kv-server_v1.1.0_darwin_amd64.tar.gz", "SHA256SUMS"])
        let lookup = BackendReleaseLookup(fetcher: StubFetcher(json), architecture: .arm64)

        await #expect(throws: BackendReleaseError.missingArchive("darwin_arm64")) {
            try await lookup.latest()
        }
    }

    @Test func reportsMissingChecksums() async throws {
        let json = releaseJSON(assets: ["kv-server_v1.1.0_darwin_arm64.tar.gz"])
        let lookup = BackendReleaseLookup(fetcher: StubFetcher(json), architecture: .arm64)

        await #expect(throws: BackendReleaseError.missingChecksums) { try await lookup.latest() }
    }

    @Test func rejectsATagThatIsNotASemanticVersion() async throws {
        let lookup = BackendReleaseLookup(fetcher: StubFetcher(releaseJSON(tag: "nightly")), architecture: .arm64)

        await #expect(throws: BackendReleaseError.unusableVersion("nightly")) { try await lookup.latest() }
    }

    @Test func rejectsAResponseThatIsNotReleaseJSON() async throws {
        let lookup = BackendReleaseLookup(fetcher: StubFetcher("not json at all"), architecture: .arm64)

        await #expect(throws: BackendReleaseError.unreadableResponse) { try await lookup.latest() }
    }

    @Test func propagatesTheFetcherFailure() async throws {
        let lookup = BackendReleaseLookup(fetcher: StubFetcher(failing: StubError.offline), architecture: .arm64)

        await #expect(throws: StubError.offline) { try await lookup.latest() }
    }

    @Test func toleratesAssetsItDoesNotUnderstand() async throws {
        let json = releaseJSON(assets: [
            "kv-server_v1.1.0_darwin_arm64.tar.gz",
            "SHA256SUMS",
            "release-notes.md"
        ])
        let lookup = BackendReleaseLookup(fetcher: StubFetcher(json), architecture: .arm64)

        let release = try await lookup.latest()

        #expect(release.archive.name == "kv-server_v1.1.0_darwin_arm64.tar.gz")
    }

    @Test func exposesTheDownloadURLWithoutFetchingIt() async throws {
        let lookup = BackendReleaseLookup(fetcher: StubFetcher(releaseJSON()), architecture: .arm64)

        let release = try await lookup.latest()

        #expect(release.archive.url.absoluteString.hasSuffix("darwin_arm64.tar.gz"))
        #expect(release.checksums.url.absoluteString.hasSuffix("SHA256SUMS"))
    }
}

@Suite
struct HostArchitectureTests {

    @Test func reportsAnArchitectureThisMachineCouldRun() {
        #expect([HostArchitecture.arm64, .amd64].contains(HostArchitecture.current))
    }

    @Test func namesMatchTheReleaseAssetSuffixes() {
        #expect(HostArchitecture.arm64.assetSuffix == "darwin_arm64")
        #expect(HostArchitecture.amd64.assetSuffix == "darwin_amd64")
    }
}
