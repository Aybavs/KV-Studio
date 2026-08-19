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

    // A recorded pid that now belongs to a different process must not read as alive.
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

    @Test func treatsAbsentIdentityAsNotAlive() {
        #expect(!ProcessIdentity.isAlive(pid: 900_000, since: nil))
        #expect(ProcessIdentity.isAlive(pid: getpid(), since: nil))
    }
}
