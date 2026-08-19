import Testing
import Foundation
import Darwin
@testable import KV_Studio

@Suite(.timeLimit(.minutes(1)))
struct ManagedServerHostTests {

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-host-\(UUID().uuidString)", isDirectory: true)
        let paths = ManagedPaths(root: root)
        try paths.createDirectoryTree()
        return paths
    }

    private func record(pid: pid_t, identity: ProcessStartTime?, paths: ManagedPaths) throws {
        try ManagedServerRecordStore(paths: paths).save(ManagedServerRecord(
            pid: pid,
            host: "127.0.0.1",
            port: 6_380,
            binaryPath: "/tmp/kv-server",
            processStartTime: identity,
            startedAt: Date()
        ))
    }

    @Test func stopReportsUnreclaimedWhenTheRecordStillNamesALiveProcess() async throws {
        let paths = try makePaths()
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let script = try await fixtures.launchableScript(named: "survivor", body: FixtureScript.sleepsForever)
        let survivor = Process()
        survivor.executableURL = script
        survivor.standardOutput = FileHandle.nullDevice
        survivor.standardError = FileHandle.nullDevice
        try survivor.run()
        defer {
            kill(survivor.processIdentifier, SIGKILL)
            survivor.waitUntilExit()
        }
        try await fixtures.waitUntilReady(script)

        let pid = survivor.processIdentifier
        try record(pid: pid, identity: ProcessIdentity.startTime(of: pid), paths: paths)
        let host = ManagedServerHost(controller: ManagedServerController(paths: paths), paths: paths)

        // The controller reports .stopped here; the preserved record says otherwise.
        #expect(await host.stop() == .unreclaimed(pid))
    }

    @Test func stopReportsStoppedWhenNoRecordSurvives() async throws {
        let paths = try makePaths()
        let host = ManagedServerHost(controller: ManagedServerController(paths: paths), paths: paths)

        #expect(await host.stop() == .stopped)
    }

    @Test func stopReportsStoppedWhenTheRecordNamesAProcessThatIsGone() async throws {
        let paths = try makePaths()
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let script = try await fixtures.launchableScript(named: "gone", body: FixtureScript.sleepsForever)
        let process = Process()
        process.executableURL = script
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try await fixtures.waitUntilReady(script)
        let pid = process.processIdentifier
        let identity = ProcessIdentity.startTime(of: pid)
        kill(pid, SIGKILL)
        process.waitUntilExit()

        try record(pid: pid, identity: identity, paths: paths)
        let host = ManagedServerHost(controller: ManagedServerController(paths: paths), paths: paths)

        #expect(await host.stop() == .stopped)
    }
}
