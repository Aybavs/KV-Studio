import Foundation
import Darwin
import Testing
@testable import KV_Studio

@Suite(.timeLimit(.minutes(2)))
struct ManagedServerControllerTests {

    // Comfortably above the few hundred ms macOS spends vetting a freshly written executable.
    private let timeouts = ManagedServerTimeouts(
        readiness: .seconds(2),
        readinessPoll: .milliseconds(20),
        gracefulShutdown: .milliseconds(500),
        forcedShutdown: .seconds(2)
    )

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-controller-\(UUID().uuidString)", isDirectory: true)
        let paths = ManagedPaths(root: root)
        try paths.createDirectoryTree()
        return paths
    }

    private func usePort(_ port: UInt16, in paths: ManagedPaths) throws {
        try PreferencesStore(paths: paths).savePreferences(
            Preferences(localBindHost: "127.0.0.1", localPort: port)
        )
    }

    private func resolver(_ binary: URL?) -> ServerBinaryResolver {
        ServerBinaryResolver(
            environment: binary.map { [ServerBinaryResolver.overrideEnvironmentKey: $0.path] } ?? [:],
            bundledBinary: nil
        )
    }

    private func waitUntilGone(pid: pid_t, since identity: ProcessStartTime?) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ProcessIdentity.isAlive(pid: pid, since: identity) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Resolution

    @Test func startsInTheStoppedState() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let controller = ManagedServerController(paths: paths, resolver: resolver(nil), timeouts: timeouts)

        #expect(await controller.state == .stopped)
        #expect(await controller.endpoint == nil)
    }

    @Test func failsWithAnActionableErrorWhenNoBinaryResolves() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try usePort(try KVServerProcess.allocatePort(), in: paths)
        let controller = ManagedServerController(paths: paths, resolver: resolver(nil), timeouts: timeouts)

        let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }
        guard case .binaryUnavailable(let checked) = try #require(error) else {
            Issue.record("expected binaryUnavailable, got \(String(describing: error))")
            return
        }
        #expect(checked == [paths.backendCurrentBinary.path])

        guard case .failed(let message) = await controller.state else {
            Issue.record("expected failed state")
            return
        }
        #expect(message.contains(paths.backendCurrentBinary.path))
        #expect(ManagedServerRecordStore(paths: paths).load() == nil)
    }

    @Test func createsTheManagedDirectoryTreeBeforeLaunching() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-controller-\(UUID().uuidString)", isDirectory: true)
        let paths = ManagedPaths(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ManagedServerController(paths: paths, resolver: resolver(nil), timeouts: timeouts)

        _ = try? await controller.start()

        #expect(FileManager.default.fileExists(atPath: paths.dataDir.path))
        #expect(FileManager.default.fileExists(atPath: paths.logsDir.path))
        #expect(FileManager.default.fileExists(atPath: paths.stateDir.path))
    }

    // MARK: - Startup failures

    @Test func reportsAChildThatExitsDuringStartup() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        try usePort(try KVServerProcess.allocatePort(), in: paths)

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.exitsEarly)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)

        let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }
        #expect(error == .exitedDuringStartup(3))
        #expect(ManagedServerRecordStore(paths: paths).load() == nil)
        #expect(await controller.endpoint == nil)
    }

    // A timed-out child we spawned is an orphan of our own making, so it must not outlive the attempt.
    @Test func terminatesTheChildWhenReadinessTimesOut() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        try usePort(try KVServerProcess.allocatePort(), in: paths)

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.sleepsForever)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)

        let starting = Task { try await controller.start() }
        try await fixtures.waitUntilReady(script)
        let pid = try fixtures.pid(of: script)

        let error = await #expect(throws: ManagedServerError.self) { try await starting.value }
        guard case .readinessTimedOut = try #require(error) else {
            Issue.record("expected readinessTimedOut, got \(String(describing: error))")
            return
        }

        try await waitUntilGone(pid: pid, since: nil)
        #expect(!ProcessIdentity.isAlive(pid: pid, since: nil))
        #expect(ManagedServerRecordStore(paths: paths).load() == nil)
        #expect(await controller.endpoint == nil)
    }

    // Escalation has to work through the controller too, not only in isolation.
    @Test func killsATimedOutChildThatIgnoresTermination() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        try usePort(try KVServerProcess.allocatePort(), in: paths)

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.ignoresTermination)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)

        let starting = Task { try await controller.start() }
        try await fixtures.waitUntilReady(script)
        let pid = try fixtures.pid(of: script)

        _ = await #expect(throws: ManagedServerError.self) { try await starting.value }

        try await waitUntilGone(pid: pid, since: nil)
        #expect(!ProcessIdentity.isAlive(pid: pid, since: nil))
    }

    @Test func capturesChildOutputToTheLogFileAndStream() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        try usePort(try KVServerProcess.allocatePort(), in: paths)

        let script = try await fixtures.launchableScript(
            named: "kv-server",
            body: "echo out-line\necho err-line >&2\n" + FixtureScript.sleepsForever
        )
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)
        let collector = LineCollector()
        let reader = Task {
            for await line in controller.outputLines { collector.append(line) }
        }

        let starting = Task { try await controller.start() }
        try await fixtures.waitUntilReady(script)
        _ = await #expect(throws: ManagedServerError.self) { try await starting.value }
        reader.cancel()

        let log = try String(contentsOf: paths.logFile, encoding: .utf8)
        #expect(log.contains("out-line"))
        #expect(log.contains("err-line"))

        let lines = collector.snapshot()
        #expect(lines.contains("out-line"))
        #expect(lines.contains("err-line"))
    }

    // MARK: - Port ownership

    @Test func refusesToStartWhenSomethingElseOwnsThePort() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let holder = try PortHolder()
        defer { holder.close() }
        try usePort(holder.port, in: paths)

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.sleepsForever)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)

        let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }
        #expect(error == .portInUse(ConnectionEndpoint(host: "127.0.0.1", port: holder.port)))
        #expect(holder.isStillListening)
        #expect(!FileManager.default.fileExists(atPath: script.path + ".pid"))
        #expect(ManagedServerRecordStore(paths: paths).load() == nil)
    }

    // MARK: - Adoption

    @Test func doesNotAdoptARecordWhosePIDNowBelongsToAnotherProcess() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let port = try KVServerProcess.allocatePort()
        try usePort(port, in: paths)

        let stranger = try await fixtures.launchableScript(named: "stranger", body: FixtureScript.sleepsForever)
        let strangerProcess = Process()
        strangerProcess.executableURL = stranger
        strangerProcess.standardOutput = FileHandle.nullDevice
        strangerProcess.standardError = FileHandle.nullDevice
        try strangerProcess.run()
        let strangerPID = strangerProcess.processIdentifier
        defer { kill(strangerPID, SIGKILL) }
        try await fixtures.waitUntilReady(stranger)
        let strangerIdentity = try #require(ProcessIdentity.startTime(of: strangerPID))

        let stale = ProcessStartTime(seconds: strangerIdentity.seconds - 3600, microseconds: strangerIdentity.microseconds)
        try ManagedServerRecordStore(paths: paths).save(
            ManagedServerRecord(
                pid: strangerPID,
                host: "127.0.0.1",
                port: port,
                binaryPath: stranger.path,
                processStartTime: stale,
                startedAt: Date()
            )
        )

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.exitsEarly)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)

        let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }
        #expect(error == .exitedDuringStartup(3))
        #expect(await controller.state != .running(strangerPID))
        #expect(ProcessIdentity.isAlive(pid: strangerPID, since: strangerIdentity))
        #expect(ManagedServerRecordStore(paths: paths).load() == nil)
    }

    @Test func doesNotAdoptARecordThatNoLongerAnswersPing() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let port = try KVServerProcess.allocatePort()
        try usePort(port, in: paths)

        let stranger = try await fixtures.launchableScript(named: "stranger", body: FixtureScript.sleepsForever)
        let strangerProcess = Process()
        strangerProcess.executableURL = stranger
        strangerProcess.standardOutput = FileHandle.nullDevice
        strangerProcess.standardError = FileHandle.nullDevice
        try strangerProcess.run()
        let strangerPID = strangerProcess.processIdentifier
        defer { kill(strangerPID, SIGKILL) }
        try await fixtures.waitUntilReady(stranger)
        let strangerIdentity = try #require(ProcessIdentity.startTime(of: strangerPID))

        try ManagedServerRecordStore(paths: paths).save(
            ManagedServerRecord(
                pid: strangerPID,
                host: "127.0.0.1",
                port: port,
                binaryPath: stranger.path,
                processStartTime: strangerIdentity,
                startedAt: Date()
            )
        )

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.exitsEarly)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)

        let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }
        #expect(error == .exitedDuringStartup(3))
        #expect(ProcessIdentity.isAlive(pid: strangerPID, since: strangerIdentity))
    }

    @Test func discardsARecordWhosePIDIsGone() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = ManagedServerRecordStore(paths: paths)
        try usePort(try KVServerProcess.allocatePort(), in: paths)
        try store.save(
            ManagedServerRecord(
                pid: 900_001,
                host: "127.0.0.1",
                port: 6380,
                binaryPath: "/nowhere/kv-server",
                processStartTime: ProcessStartTime(seconds: 1, microseconds: 1),
                startedAt: Date()
            )
        )

        let controller = ManagedServerController(paths: paths, resolver: resolver(nil), timeouts: timeouts)
        _ = await #expect(throws: ManagedServerError.self) { try await controller.start() }

        #expect(store.load() == nil)
    }

    // MARK: - Stop

    @Test func stoppingWhenNothingRunsIsIdempotent() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let controller = ManagedServerController(paths: paths, resolver: resolver(nil), timeouts: timeouts)

        await controller.stop()
        await controller.stop()
        #expect(await controller.state == .stopped)
    }

    // stop() racing start() must never leave a live process behind a `stopped` controller.
    @Test func stopTerminatesAChildThatIsStillStarting() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        try usePort(try KVServerProcess.allocatePort(), in: paths)

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.sleepsForever)
        var patient = timeouts
        patient.readiness = .seconds(30)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: patient)

        let starting = Task { try await controller.start() }
        try await fixtures.waitUntilReady(script)
        let pid = try fixtures.pid(of: script)

        await controller.stop()

        #expect(await controller.state == .stopped)
        #expect(await controller.endpoint == nil)
        try await waitUntilGone(pid: pid, since: nil)
        #expect(!ProcessIdentity.isAlive(pid: pid, since: nil))
        #expect(ManagedServerRecordStore(paths: paths).load() == nil)
        _ = await #expect(throws: (any Error).self) { try await starting.value }
    }
}
