import Foundation
import Testing
@testable import KV_Studio

@Suite
struct ChecksumManifestTests {

    private let real = """
    bac9c951a4b960dfbfe90d0047b874c1f6caced3accbc5253c0f26f5073bf830  kv-server_v1.1.0_darwin_amd64.tar.gz
    c6f058bc815b02deea5c7737ac24fc4e286bccd75e330d7296af5cb93e4ed6d2  kv-server_v1.1.0_darwin_arm64.tar.gz
    a4439940c0d5600b66e02c5523eb66d0aea9aee3c25198f6d4f3ba2d144c49ad  kv-server_v1.1.0_linux_amd64.tar.gz
    ac2edc8aa416a3c880eb744bb16e5bab0d5bda5970467513faaa81783a154542  kv-server_v1.1.0_linux_arm64.tar.gz

    """

    @Test func readsTheRealReleaseManifest() throws {
        let manifest = try ChecksumManifest(data: Data(real.utf8))

        #expect(manifest.digest(for: "kv-server_v1.1.0_darwin_arm64.tar.gz")
            == "c6f058bc815b02deea5c7737ac24fc4e286bccd75e330d7296af5cb93e4ed6d2")
    }

    @Test func doesNotKnowAFileItWasNeverGiven() throws {
        let manifest = try ChecksumManifest(data: Data(real.utf8))
        #expect(manifest.digest(for: "kv-server_v9.9.9_darwin_arm64.tar.gz") == nil)
    }

    // A prefix or suffix must not be mistaken for the entry it resembles.
    @Test func matchesTheWholeFilenameOnly() throws {
        let manifest = try ChecksumManifest(data: Data(real.utf8))
        #expect(manifest.digest(for: "darwin_arm64.tar.gz") == nil)
        #expect(manifest.digest(for: "kv-server_v1.1.0_darwin_arm64.tar") == nil)
    }

    @Test func acceptsASingleSpaceSeparator() throws {
        let manifest = try ChecksumManifest(data: Data("""
        c6f058bc815b02deea5c7737ac24fc4e286bccd75e330d7296af5cb93e4ed6d2 archive.tar.gz
        """.utf8))
        #expect(manifest.digest(for: "archive.tar.gz") != nil)
    }

    @Test func ignoresBlankLines() throws {
        let manifest = try ChecksumManifest(data: Data("""

        c6f058bc815b02deea5c7737ac24fc4e286bccd75e330d7296af5cb93e4ed6d2  archive.tar.gz

        """.utf8))
        #expect(manifest.digest(for: "archive.tar.gz") != nil)
    }

    @Test func rejectsADigestThatIsNotSixtyFourHexCharacters() {
        #expect(throws: BackendStagingError.checksumsUnreadable) {
            try ChecksumManifest(data: Data("abc  archive.tar.gz".utf8))
        }
    }

    @Test func rejectsANonHexDigest() {
        let notHex = String(repeating: "z", count: 64)
        #expect(throws: BackendStagingError.checksumsUnreadable) {
            try ChecksumManifest(data: Data("\(notHex)  archive.tar.gz".utf8))
        }
    }

    @Test func rejectsALineWithNoFilename() {
        let digest = String(repeating: "a", count: 64)
        #expect(throws: BackendStagingError.checksumsUnreadable) {
            try ChecksumManifest(data: Data("\(digest)".utf8))
        }
    }

    @Test func rejectsAManifestThatIsNotUTF8() {
        #expect(throws: BackendStagingError.checksumsUnreadable) {
            try ChecksumManifest(data: Data([0xFF, 0xFE, 0x00]))
        }
    }

    @Test func comparesDigestsWithoutCaringAboutCase() throws {
        let digest = String(repeating: "A", count: 64)
        let manifest = try ChecksumManifest(data: Data("\(digest)  archive.tar.gz".utf8))
        #expect(manifest.digest(for: "archive.tar.gz") == String(repeating: "a", count: 64))
    }
}
