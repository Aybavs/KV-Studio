import Testing
@testable import KV_Studio

struct SemanticVersionTests {

    @Test func parsesPlainVersion() throws {
        let version = try #require(SemanticVersion(string: "1.1.0"))
        #expect(version.major == 1)
        #expect(version.minor == 1)
        #expect(version.patch == 0)
        #expect(version.prerelease == nil)
    }

    @Test func parsesLeadingVPrefix() throws {
        let version = try #require(SemanticVersion(string: "v1.1.0"))
        #expect(version.major == 1)
        #expect(version.minor == 1)
        #expect(version.patch == 0)
    }

    @Test func comparesMinorVersionNumerically() throws {
        let bigger = try #require(SemanticVersion(string: "1.10.0"))
        let smaller = try #require(SemanticVersion(string: "1.2.0"))
        #expect(bigger > smaller)
    }

    @Test func rejectsMalformedVersions() {
        #expect(SemanticVersion(string: "") == nil)
        #expect(SemanticVersion(string: "abc") == nil)
        #expect(SemanticVersion(string: "1.2") == nil)
        #expect(SemanticVersion(string: "1.2.3.4") == nil)
        #expect(SemanticVersion(string: "1.2.x") == nil)
        #expect(SemanticVersion(string: "1.-2.0") == nil)
    }

    @Test func prereleaseOrdersBelowSameCoreVersion() throws {
        let prerelease = try #require(SemanticVersion(string: "1.2.3-beta"))
        let release = try #require(SemanticVersion(string: "1.2.3"))
        #expect(prerelease < release)
        #expect(release > prerelease)
    }
}
