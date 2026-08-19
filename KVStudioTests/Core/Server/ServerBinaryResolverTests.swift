import Foundation
import Testing
@testable import KV_Studio

@Suite(.timeLimit(.minutes(1)))
struct ServerBinaryResolverTests {

    private func makePaths() -> ManagedPaths {
        ManagedPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test func prefersEnvironmentOverride() throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let paths = makePaths()
        try paths.createDirectoryTree()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let override = try fixtures.script(named: "override", body: "exit 0\n")
        let managed = try fixtures.script(named: "managed", body: "exit 0\n")
        try FileManager.default.copyItem(at: managed, to: paths.backendCurrentBinary)

        let resolver = ServerBinaryResolver(
            environment: [ServerBinaryResolver.overrideEnvironmentKey: override.path],
            bundledBinary: nil
        )
        #expect(try resolver.resolve(in: paths) == override)
    }

    @Test func fallsThroughToManagedBinaryWhenOverrideIsMissing() throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let paths = makePaths()
        try paths.createDirectoryTree()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let managed = try fixtures.script(named: "managed", body: "exit 0\n")
        try FileManager.default.copyItem(at: managed, to: paths.backendCurrentBinary)

        let resolver = ServerBinaryResolver(
            environment: [ServerBinaryResolver.overrideEnvironmentKey: fixtures.missingPath(named: "nope").path],
            bundledBinary: nil
        )
        #expect(try resolver.resolve(in: paths) == paths.backendCurrentBinary)
    }

    @Test func fallsThroughToBundledBinaryLast() throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let paths = makePaths()

        let bundled = try fixtures.script(named: "bundled", body: "exit 0\n")
        let resolver = ServerBinaryResolver(environment: [:], bundledBinary: bundled)
        #expect(try resolver.resolve(in: paths) == bundled)
    }

    @Test func skipsCandidatesThatAreNotExecutableFiles() throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let paths = makePaths()
        try paths.createDirectoryTree()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let plainFile = try fixtures.nonExecutableFile(named: "not-executable")
        let bundled = try fixtures.script(named: "bundled", body: "exit 0\n")

        let resolver = ServerBinaryResolver(
            environment: [ServerBinaryResolver.overrideEnvironmentKey: plainFile.path],
            bundledBinary: bundled
        )
        #expect(try resolver.resolve(in: paths) == bundled)
    }

    // backend/current exists as a directory before anything installs a binary into it.
    @Test func doesNotMistakeADirectoryForABinary() throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let paths = makePaths()
        try paths.createDirectoryTree()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.backendCurrentBinary, withIntermediateDirectories: true)

        let resolver = ServerBinaryResolver(environment: [:], bundledBinary: nil)
        #expect(throws: ManagedServerError.self) { try resolver.resolve(in: paths) }
    }

    @Test func reportsEveryCandidateItChecked() throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let paths = makePaths()
        let override = fixtures.missingPath(named: "override")

        let resolver = ServerBinaryResolver(
            environment: [ServerBinaryResolver.overrideEnvironmentKey: override.path],
            bundledBinary: nil
        )

        let error = #expect(throws: ManagedServerError.self) { try resolver.resolve(in: paths) }
        guard case .binaryUnavailable(let checked) = try #require(error) else {
            Issue.record("expected binaryUnavailable")
            return
        }
        #expect(checked == [override.path, paths.backendCurrentBinary.path])
        let message = try #require(error?.errorDescription)
        #expect(message.contains(ServerBinaryResolver.overrideEnvironmentKey))
        #expect(message.contains(paths.backendCurrentBinary.path))
    }
}
