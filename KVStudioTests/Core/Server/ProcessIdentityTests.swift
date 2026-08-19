import Foundation
import Darwin
import Testing
@testable import KV_Studio

@Suite(.timeLimit(.minutes(1)))
struct ProcessIdentityTests {

    @Test func readsStartTimeOfLiveProcess() {
        let identity = ProcessIdentity.startTime(of: getpid())
        #expect(identity != nil)
        #expect(ProcessIdentity.startTime(of: getpid()) == identity)
    }

    @Test func reportsNoIdentityForUnusedPID() {
        #expect(ProcessIdentity.startTime(of: 0) == nil)
        #expect(ProcessIdentity.startTime(of: -1) == nil)
        #expect(ProcessIdentity.startTime(of: 900_000) == nil)
    }

    @Test func distinguishesTwoLiveProcesses() async throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let script = try await fixtures.launchableScript(named: "sleeper", body: FixtureScript.sleepsForever)

        let process = Process()
        process.executableURL = script
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { kill(process.processIdentifier, SIGKILL) }

        let childIdentity = try #require(ProcessIdentity.startTime(of: process.processIdentifier))
        let selfIdentity = try #require(ProcessIdentity.startTime(of: getpid()))
        #expect(childIdentity != selfIdentity)
    }

    @Test func rejectsRecycledPID() async throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let script = try await fixtures.launchableScript(named: "sleeper", body: FixtureScript.sleepsForever)

        let process = Process()
        process.executableURL = script
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { kill(process.processIdentifier, SIGKILL) }

        let pid = process.processIdentifier
        let actual = try #require(ProcessIdentity.startTime(of: pid))
        let stale = ProcessStartTime(seconds: actual.seconds - 60, microseconds: actual.microseconds)

        #expect(ProcessIdentity.isAlive(pid: pid, since: actual))
        #expect(!ProcessIdentity.isAlive(pid: pid, since: stale))
    }

    @Test func refusesToVouchForAPIDWithoutARecordedIdentity() {
        #expect(!ProcessIdentity.isAlive(pid: getpid(), since: nil))
        #expect(!ProcessIdentity.isAlive(pid: 900_000, since: nil))
    }

    @Test func reportsWhetherAPIDIsInUse() async throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let script = try await fixtures.launchableScript(named: "sleeper", body: FixtureScript.sleepsForever)

        let process = Process()
        process.executableURL = script
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier

        #expect(ProcessIdentity.isPIDInUse(pid))
        #expect(ProcessIdentity.isPIDInUse(getpid()))
        #expect(!ProcessIdentity.isPIDInUse(900_000))

        kill(pid, SIGKILL)
        while ProcessIdentity.isPIDInUse(pid) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func readsTheExecutablePathOfALiveProcess() throws {
        let path = try #require(ProcessIdentity.executablePath(of: getpid()))
        #expect(path.hasSuffix("xctest") || path.contains("KV Studio"))
        #expect(ProcessIdentity.executablePath(of: 900_000) == nil)
    }

    @Test func findsProcessesByExecutablePathAndStartTime() throws {
        let path = try #require(ProcessIdentity.executablePath(of: getpid()))

        #expect(ProcessIdentity.pids(runningExecutableAt: path, startedNoEarlierThan: .distantPast).contains(getpid()))
        #expect(ProcessIdentity.pids(
            runningExecutableAt: path,
            startedNoEarlierThan: Date().addingTimeInterval(3600)
        ).isEmpty)
        #expect(ProcessIdentity.pids(
            runningExecutableAt: "/nowhere/kv-server",
            startedNoEarlierThan: .distantPast
        ).isEmpty)
    }
}
