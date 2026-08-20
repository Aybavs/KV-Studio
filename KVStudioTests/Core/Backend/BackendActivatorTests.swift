import Foundation
import Testing
@testable import KV_Studio

private actor RecordingHost: ManagedServerHosting {
    private(set) var events: [String] = []
    private var startFailures: Int
    private let endpoint: ConnectionEndpoint

    nonisolated var outputLines: AsyncStream<String> { AsyncStream { $0.finish() } }

    init(endpoint: ConnectionEndpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380), startFailures: Int = 0) {
        self.endpoint = endpoint
        self.startFailures = startFailures
    }

    func start() async throws -> ManagedServerHandle {
        events.append("start")
        if startFailures > 0 {
            startFailures -= 1
            throw ManagedServerError.launchFailed("stubbed")
        }
        return ManagedServerHandle(pid: 1234, endpoint: endpoint)
    }

    func stop() async -> ManagedServerStopOutcome {
        events.append("stop")
        return .stopped
    }
}

private struct StubProber: BackendProbing {
    let outcome: CompatibilityOutcome
    func probe(_ endpoint: ConnectionEndpoint) async throws -> CompatibilityOutcome { outcome }
}

@Suite
struct BackendActivatorTests {

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-activate-\(UUID().uuidString)", isDirectory: true)
        let paths = ManagedPaths(root: root)
        try paths.createDirectoryTree()
        return paths
    }

    private func writeBackend(_ directory: URL, marker: String, version: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("kv-server")
        try Data("#!/bin/sh\necho \(marker)\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let metadata = ["version": version, "sha256": String(repeating: "a", count: 64)]
        try JSONSerialization.data(withJSONObject: metadata)
            .write(to: directory.appendingPathComponent("metadata.json"))
    }

    private func marker(at binary: URL) throws -> String {
        try String(contentsOf: binary, encoding: .utf8)
            .split(separator: "\n").last.map(String.init) ?? ""
    }

    @Test func refusesWhenNothingIsStaged() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        await #expect(throws: BackendActivationError.nothingStaged) {
            try await BackendActivator(paths: paths, host: RecordingHost(), prober: StubProber(outcome: .compatible)).activate()
        }
    }

    @Test func swapsInTheStagedBackendAndKeepsThePreviousOne() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writeBackend(paths.backendCurrentDir, marker: "old", version: "1.0.1")
        try writeBackend(paths.backendStagingDir, marker: "new", version: "1.1.0")
        let host = RecordingHost()

        let activation = try await BackendActivator(
            paths: paths, host: host, prober: StubProber(outcome: .compatible)
        ).activate()

        #expect(activation.version == SemanticVersion(string: "1.1.0"))
        #expect(try marker(at: paths.backendCurrentBinary).contains("new"))
        #expect(try marker(at: paths.backendPreviousDir.appendingPathComponent("kv-server")).contains("old"))
        #expect(await host.events == ["stop", "start"])
    }

    @Test func leavesAnEmptyStagingDirectoryBehind() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writeBackend(paths.backendCurrentDir, marker: "old", version: "1.0.1")
        try writeBackend(paths.backendStagingDir, marker: "new", version: "1.1.0")

        _ = try await BackendActivator(
            paths: paths, host: RecordingHost(), prober: StubProber(outcome: .compatible)
        ).activate()

        let staged = try FileManager.default.contentsOfDirectory(atPath: paths.backendStagingDir.path)
        #expect(staged.isEmpty)
    }

    @Test func carriesTheStagedMetadataIntoCurrent() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writeBackend(paths.backendCurrentDir, marker: "old", version: "1.0.1")
        try writeBackend(paths.backendStagingDir, marker: "new", version: "1.1.0")

        _ = try await BackendActivator(
            paths: paths, host: RecordingHost(), prober: StubProber(outcome: .compatible)
        ).activate()

        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: paths.backendCurrentMetadata)) as? [String: Any]
        #expect(json?["version"] as? String == "1.1.0")
    }

    @Test func restoresThePreviousBackendWhenTheNewOneFailsItsProbe() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writeBackend(paths.backendCurrentDir, marker: "old", version: "1.0.1")
        try writeBackend(paths.backendStagingDir, marker: "new", version: "1.1.0")
        let host = RecordingHost()
        let prober = StubProber(outcome: .incompatible(
            step: .dbSize,
            reason: .serverError(class: .unknownCommand, message: "ERR unknown command 'DBSIZE'")
        ))

        await #expect(throws: BackendActivationError.self) {
            try await BackendActivator(paths: paths, host: host, prober: prober).activate()
        }

        #expect(try marker(at: paths.backendCurrentBinary).contains("old"))
        #expect(await host.events == ["stop", "start", "stop", "start"])
    }

    @Test func restoresThePreviousBackendWhenTheNewOneWillNotStart() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writeBackend(paths.backendCurrentDir, marker: "old", version: "1.0.1")
        try writeBackend(paths.backendStagingDir, marker: "new", version: "1.1.0")
        let host = RecordingHost(startFailures: 1)

        await #expect(throws: BackendActivationError.self) {
            try await BackendActivator(paths: paths, host: host, prober: StubProber(outcome: .compatible)).activate()
        }

        #expect(try marker(at: paths.backendCurrentBinary).contains("old"))
    }

    @Test func reportsWhenThereIsNoPreviousBackendToRestore() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writeBackend(paths.backendStagingDir, marker: "new", version: "1.1.0")
        let host = RecordingHost(startFailures: 1)

        await #expect(throws: BackendActivationError.self) {
            try await BackendActivator(paths: paths, host: host, prober: StubProber(outcome: .compatible)).activate()
        }
    }

    @Test func stopsTheServerBeforeTouchingTheBinary() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writeBackend(paths.backendCurrentDir, marker: "old", version: "1.0.1")
        try writeBackend(paths.backendStagingDir, marker: "new", version: "1.1.0")
        let host = RecordingHost()

        _ = try await BackendActivator(paths: paths, host: host, prober: StubProber(outcome: .compatible)).activate()

        #expect(await host.events.first == "stop")
    }
}
