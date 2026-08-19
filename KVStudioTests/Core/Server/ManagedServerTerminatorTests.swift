import Foundation
import Darwin
import Testing
@testable import KV_Studio

@Suite(.timeLimit(.minutes(1)))
struct ManagedServerTerminatorTests {

    private func launch(_ script: URL) throws -> Process {
        let process = Process()
        process.executableURL = script
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    // terminationStatus is only meaningful once Foundation has reaped the child.
    private func awaitReaping(_ process: Process) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func terminatesCooperativeProcessGracefully() async throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let process = try launch(try await fixtures.launchableScript(named: "sleeper", body: FixtureScript.sleepsForever))
        let pid = process.processIdentifier
        defer { kill(pid, SIGKILL) }
        let identity = ProcessIdentity.startTime(of: pid)

        let started = ContinuousClock.now
        let outcome = await ManagedServerTerminator.terminate(
            pid: pid,
            since: identity,
            graceful: .seconds(10),
            forced: .seconds(2)
        )

        #expect(outcome == .exitedGracefully)
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(!ProcessIdentity.isAlive(pid: pid, since: identity))
        try await awaitReaping(process)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGTERM)
    }

    @Test func escalatesToSIGKILLWhenTerminationIsIgnored() async throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let script = try await fixtures.launchableScript(named: "stubborn", body: FixtureScript.ignoresTermination)
        let process = try launch(script)
        let pid = process.processIdentifier
        defer { kill(pid, SIGKILL) }
        try await fixtures.waitUntilReady(script)
        let identity = ProcessIdentity.startTime(of: pid)

        let started = ContinuousClock.now
        let outcome = await ManagedServerTerminator.terminate(
            pid: pid,
            since: identity,
            graceful: .milliseconds(400),
            forced: .seconds(2)
        )
        let elapsed = started.duration(to: .now)

        #expect(outcome == .forced)
        #expect(elapsed >= .milliseconds(400))
        #expect(elapsed < .seconds(5))
        #expect(!ProcessIdentity.isAlive(pid: pid, since: identity))
        try await awaitReaping(process)
        #expect(process.terminationStatus == SIGKILL)
    }

    @Test func reportsNotRunningForADeadProcess() async throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let process = try launch(try await fixtures.launchableScript(named: "sleeper", body: FixtureScript.sleepsForever))
        let pid = process.processIdentifier
        let identity = ProcessIdentity.startTime(of: pid)
        kill(pid, SIGKILL)
        while ProcessIdentity.isAlive(pid: pid, since: identity) {
            try await Task.sleep(for: .milliseconds(10))
        }

        let outcome = await ManagedServerTerminator.terminate(
            pid: pid,
            since: identity,
            graceful: .seconds(10),
            forced: .seconds(2)
        )
        #expect(outcome == .notRunning)
    }

    @Test func refusesToSignalAProcessWhoseIdentityDoesNotMatch() async throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let process = try launch(try await fixtures.launchableScript(named: "sleeper", body: FixtureScript.sleepsForever))
        let pid = process.processIdentifier
        defer { kill(pid, SIGKILL) }
        let actual = try #require(ProcessIdentity.startTime(of: pid))
        let stale = ProcessStartTime(seconds: actual.seconds - 60, microseconds: actual.microseconds)

        let outcome = await ManagedServerTerminator.terminate(
            pid: pid,
            since: stale,
            graceful: .milliseconds(200),
            forced: .milliseconds(200)
        )

        #expect(outcome == .notRunning)
        #expect(ProcessIdentity.isAlive(pid: pid, since: actual))
    }

    @Test func refusesToSignalAPIDWithNoRecordedIdentity() async throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let script = try await fixtures.launchableScript(named: "sleeper", body: FixtureScript.sleepsForever)
        let process = try launch(script)
        let pid = process.processIdentifier
        defer { kill(pid, SIGKILL) }
        try await fixtures.waitUntilReady(script)

        let outcome = await ManagedServerTerminator.terminate(
            pid: pid,
            since: nil,
            graceful: .milliseconds(200),
            forced: .milliseconds(200)
        )

        #expect(outcome == .notRunning)
        #expect(ProcessIdentity.isPIDInUse(pid))
    }

    @Test func survivesCancellationOfTheCallingTask() async throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let script = try await fixtures.launchableScript(named: "stubborn", body: FixtureScript.ignoresTermination)
        let process = try launch(script)
        let pid = process.processIdentifier
        defer { kill(pid, SIGKILL) }
        try await fixtures.waitUntilReady(script)
        let identity = ProcessIdentity.startTime(of: pid)

        let task = Task {
            await ManagedServerTerminator.terminate(
                pid: pid,
                since: identity,
                graceful: .milliseconds(200),
                forced: .seconds(2)
            )
        }
        task.cancel()

        #expect(await task.value == .forced)
        #expect(!ProcessIdentity.isAlive(pid: pid, since: identity))
    }
}
