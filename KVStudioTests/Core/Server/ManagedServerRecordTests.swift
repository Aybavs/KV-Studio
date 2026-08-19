import Foundation
import Darwin
import Testing
@testable import KV_Studio

@Suite(.timeLimit(.minutes(1)))
struct ManagedServerRecordTests {

    private func makePaths() throws -> ManagedPaths {
        let paths = ManagedPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try paths.createDirectoryTree()
        return paths
    }

    private func makeRecord(pid: pid_t = 4242) -> ManagedServerRecord {
        ManagedServerRecord(
            pid: pid,
            host: "127.0.0.1",
            port: 6380,
            binaryPath: "/tmp/kv-server",
            processStartTime: ProcessStartTime(seconds: 111, microseconds: 222),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test func roundTripsThroughTheStateFile() throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = ManagedServerRecordStore(paths: paths)

        #expect(store.load() == nil)
        try store.save(makeRecord())
        #expect(store.load() == makeRecord())
        #expect(FileManager.default.fileExists(atPath: paths.managedServerFile.path))

        store.clear()
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.managedServerFile.path))
    }

    @Test func treatsCorruptStateAsAbsent() throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = ManagedServerRecordStore(paths: paths)
        try Data("{ not json".utf8).write(to: paths.managedServerFile)

        #expect(store.load() == nil)
    }

    @Test func clearingWhenNothingIsRecordedIsHarmless() throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        ManagedServerRecordStore(paths: paths).clear()
    }

    @Test func intentRecordsCarryNoProcess() throws {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let intent = ManagedServerRecord.intent(
            endpoint: endpoint,
            binaryPath: "/tmp/kv-server",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(intent.isIntent)
        #expect(!intent.identifiesLiveProcess)
        #expect(intent.endpoint == endpoint)

        let launched = intent.launched(pid: 4242, processStartTime: ProcessStartTime(seconds: 111, microseconds: 222))
        #expect(!launched.isIntent)
        #expect(launched.pid == 4242)
        #expect(launched.binaryPath == intent.binaryPath)
        #expect(launched.startedAt == intent.startedAt)
    }

    @Test func intentRecordsSurviveTheStateFile() throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = ManagedServerRecordStore(paths: paths)
        let intent = ManagedServerRecord.intent(
            endpoint: ConnectionEndpoint(host: "127.0.0.1", port: 6380),
            binaryPath: "/tmp/kv-server",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try store.save(intent)
        #expect(try #require(store.load()).isIntent)
        #expect(store.load() == intent)
    }

    @Test func exposesTheRecordedEndpoint() {
        #expect(makeRecord().endpoint == ConnectionEndpoint(host: "127.0.0.1", port: 6380))
    }

    @Test func identifiesTheRecordedProcess() async throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let process = Process()
        process.executableURL = try fixtures.script(named: "sleeper", body: FixtureScript.sleepsForever)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        defer { kill(pid, SIGKILL) }

        let identity = try #require(ProcessIdentity.startTime(of: pid))
        var record = makeRecord(pid: pid)
        record = ManagedServerRecord(
            pid: pid,
            host: record.host,
            port: record.port,
            binaryPath: record.binaryPath,
            processStartTime: identity,
            startedAt: record.startedAt
        )
        #expect(record.identifiesLiveProcess)
        #expect(!makeRecord(pid: pid).identifiesLiveProcess)
    }
}
