import Foundation
import Testing
@testable import KV_Studio

// Opt-in, off by default so the suite never depends on GitHub being reachable. xcodebuild does not
// forward the shell environment to the test process, so it must be passed as a build setting:
//   xcodebuild test -only-testing:KVStudioTests/BackendReleaseLiveTests TEST_RUNNER_KV_STUDIO_NETWORK_TESTS=1
// Exporting KV_STUDIO_NETWORK_TESTS alone leaves this suite silently skipped.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KV_STUDIO_NETWORK_TESTS"] != nil))
struct BackendReleaseLiveTests {

    @Test func findsTheRealLatestReleaseForThisMachine() async throws {
        let lookup = BackendReleaseLookup()

        let release = try await lookup.latest()

        #expect(release.version >= SemanticVersion(string: "1.1.0")!)
        #expect(release.archive.name.hasSuffix("\(HostArchitecture.current.assetSuffix).tar.gz"))
        #expect(release.archive.size > 0)
        #expect(release.archive.url.host() == "github.com")
        #expect(release.checksums.name == "SHA256SUMS")
        #expect(release.checksums.url.host() == "github.com")
    }
}
