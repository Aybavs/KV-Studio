import Foundation
import Darwin
import Testing
@testable import KV_Studio

@Suite(.timeLimit(.minutes(2)))
struct ManagedServerControllerTests {

    private let timeouts = ManagedServerTimeouts(
        readiness: .seconds(2),
        readinessPoll: .milliseconds(20),
        probe: .milliseconds(400),
        gracefulShutdown: .milliseconds(500),
        forcedShutdown: .seconds(2),
        outputDrain: .milliseconds(500)
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

    private func waitUntilGone(pid: pid_t) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ProcessIdentity.isPIDInUse(pid) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func launchStranger(_ fixtures: ProcessFixtures, named name: String = "stranger") async throws -> Process {
        let script = try await fixtures.launchableScript(named: name, body: FixtureScript.sleepsForever)
        let process = Process()
        process.executableURL = script
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try await fixtures.waitUntilReady(script)
        return process
    }

    private func pongServer() throws -> FakeServer {
        try FakeServer { peer in
            while peer.readCommand() != nil {
                peer.write(Data("+PONG\r\n".utf8))
            }
        }
    }

    private func record(
        pid: pid_t,
        identity: ProcessStartTime,
        port: UInt16,
        binaryPath: String = "/tmp/kv-server"
    ) -> ManagedServerRecord {
        ManagedServerRecord(
            pid: pid,
            host: "127.0.0.1",
            port: port,
            binaryPath: binaryPath,
            processStartTime: identity,
            startedAt: Date()
        )
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

        try await waitUntilGone(pid: pid)
        #expect(!ProcessIdentity.isPIDInUse(pid))
        #expect(ManagedServerRecordStore(paths: paths).load() == nil)
        #expect(await controller.endpoint == nil)
    }

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

        try await waitUntilGone(pid: pid)
        #expect(!ProcessIdentity.isPIDInUse(pid))
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

    @Test func launchesWithTheExactPlannedArguments() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let port = try KVServerProcess.allocatePort()
        try usePort(port, in: paths)

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.recordsArguments)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)

        let starting = Task { try await controller.start() }
        try await fixtures.waitUntilReady(script)
        _ = await #expect(throws: ManagedServerError.self) { try await starting.value }

        let arguments = try String(contentsOf: URL(fileURLWithPath: script.path + ".args"), encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(arguments == [
            "--host", "127.0.0.1",
            "--port", String(port),
            "--appendonly",
            "--appendfilename", paths.aofFile.path,
            "--appendfsync", "everysec",
            "--loglevel", "info"
        ])
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
        #expect(error == .portInUse(holder.endpoint))
        #expect(holder.isStillListening)
        #expect(!FileManager.default.fileExists(atPath: script.path + ".pid"))
        #expect(ManagedServerRecordStore(paths: paths).load() == nil)
    }

    // MARK: - Adoption

    @Test func adoptsARecordedProcessThatStillAnswersPing() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let server = try pongServer()
        defer { server.stop() }

        let stranger = try await launchStranger(fixtures)
        let pid = stranger.processIdentifier
        defer { kill(pid, SIGKILL) }
        let identity = try #require(ProcessIdentity.startTime(of: pid))

        try usePort(server.port, in: paths)
        try ManagedServerRecordStore(paths: paths).save(record(pid: pid, identity: identity, port: server.port))

        let controller = ManagedServerController(paths: paths, resolver: resolver(nil), timeouts: timeouts)
        #expect(try await controller.start() == pid)
        #expect(await controller.state == .running(pid))
        #expect(await controller.endpoint == ConnectionEndpoint(host: "127.0.0.1", port: server.port))
        #expect(ProcessIdentity.isAlive(pid: pid, since: identity))
    }

    @Test func stopsAServerItAdoptedAndClearsTheRecord() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let server = try pongServer()
        defer { server.stop() }

        let stranger = try await launchStranger(fixtures)
        let pid = stranger.processIdentifier
        defer { kill(pid, SIGKILL) }
        let identity = try #require(ProcessIdentity.startTime(of: pid))

        try usePort(server.port, in: paths)
        let store = ManagedServerRecordStore(paths: paths)
        try store.save(record(pid: pid, identity: identity, port: server.port))

        let controller = ManagedServerController(paths: paths, resolver: resolver(nil), timeouts: timeouts)
        #expect(try await controller.start() == pid)

        await controller.stop()

        #expect(await controller.state == .stopped)
        #expect(await controller.endpoint == nil)
        try await waitUntilGone(pid: pid)
        #expect(!ProcessIdentity.isPIDInUse(pid))
        #expect(store.load() == nil)
    }

    // The endpoint answers PING, so only the recorded start time can reject this record.
    @Test func doesNotAdoptARecordWhosePIDNowBelongsToAnotherProcess() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let server = try pongServer()
        defer { server.stop() }

        let stranger = try await launchStranger(fixtures)
        let pid = stranger.processIdentifier
        defer { kill(pid, SIGKILL) }
        let identity = try #require(ProcessIdentity.startTime(of: pid))
        let stale = ProcessStartTime(seconds: identity.seconds - 3600, microseconds: identity.microseconds)

        try usePort(server.port, in: paths)
        let store = ManagedServerRecordStore(paths: paths)
        try store.save(record(pid: pid, identity: stale, port: server.port))

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.exitsEarly)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)

        let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }
        #expect(error == .portInUse(ConnectionEndpoint(host: "127.0.0.1", port: server.port)))
        #expect(await controller.state != .running(pid))
        #expect(ProcessIdentity.isAlive(pid: pid, since: identity))
        #expect(store.load() == nil)
    }

    @Test func terminatesARecordedProcessOfItsOwnThatStoppedAnsweringPing() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }

        let stranger = try await launchStranger(fixtures)
        let pid = stranger.processIdentifier
        defer { kill(pid, SIGKILL) }
        let identity = try #require(ProcessIdentity.startTime(of: pid))

        let port = try KVServerProcess.allocatePort()
        try usePort(port, in: paths)
        let store = ManagedServerRecordStore(paths: paths)
        try store.save(record(pid: pid, identity: identity, port: port))

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.exitsEarly)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)

        let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }
        #expect(error == .exitedDuringStartup(3))
        try await waitUntilGone(pid: pid)
        #expect(!ProcessIdentity.isPIDInUse(pid))
        #expect(store.load() == nil)
    }

    @Test func givesUpBoundedOnAnAdoptionProbeThatNeverAnswers() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let holder = try PortHolder()
        defer { holder.close() }

        let stranger = try await launchStranger(fixtures)
        let pid = stranger.processIdentifier
        defer { kill(pid, SIGKILL) }
        let identity = try #require(ProcessIdentity.startTime(of: pid))

        try usePort(holder.port, in: paths)
        let store = ManagedServerRecordStore(paths: paths)
        try store.save(record(pid: pid, identity: identity, port: holder.port))

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.sleepsForever)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)
        let started = ContinuousClock.now
        let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }
        let elapsed = started.duration(to: .now)

        #expect(elapsed < .seconds(15))
        #expect(error == .portInUse(holder.endpoint))
        #expect(!FileManager.default.fileExists(atPath: script.path + ".pid"))
        try await waitUntilGone(pid: pid)
        #expect(!ProcessIdentity.isPIDInUse(pid))
        #expect(holder.isStillListening)
        #expect(store.load() == nil)
    }

    @Test func doesNotAdoptOntoAPortThePreferencesNoLongerName() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let server = try pongServer()
        defer { server.stop() }

        let stranger = try await launchStranger(fixtures)
        let pid = stranger.processIdentifier
        defer { kill(pid, SIGKILL) }
        let identity = try #require(ProcessIdentity.startTime(of: pid))

        try usePort(try KVServerProcess.allocatePort(), in: paths)
        let store = ManagedServerRecordStore(paths: paths)
        try store.save(record(pid: pid, identity: identity, port: server.port))

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.exitsEarly)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)

        let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }
        #expect(error == .exitedDuringStartup(3))
        #expect(await controller.state != .running(pid))
        try await waitUntilGone(pid: pid)
        #expect(!ProcessIdentity.isPIDInUse(pid))
        #expect(store.load() == nil)
    }

    @Test func discardsARecordWhosePIDIsGone() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = ManagedServerRecordStore(paths: paths)
        try usePort(try KVServerProcess.allocatePort(), in: paths)
        try store.save(
            record(pid: 900_001, identity: ProcessStartTime(seconds: 1, microseconds: 1), port: 6380)
        )

        let controller = ManagedServerController(paths: paths, resolver: resolver(nil), timeouts: timeouts)
        _ = await #expect(throws: ManagedServerError.self) { try await controller.start() }

        #expect(store.load() == nil)
    }

    // MARK: - Intent records

    @Test func discardsAnIntentRecordWhoseEndpointIsSilent() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let port = try KVServerProcess.allocatePort()
        try usePort(port, in: paths)

        let store = ManagedServerRecordStore(paths: paths)
        try store.save(
            .intent(
                endpoint: ConnectionEndpoint(host: "127.0.0.1", port: port),
                binaryPath: "/nowhere/kv-server",
                startedAt: Date()
            )
        )

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.exitsEarly)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)

        let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }
        #expect(error == .exitedDuringStartup(3))
        #expect(store.load() == nil)
    }

    @Test func reportsAStrangersPortWhenAnIntentRecordMatchesNoProcessOfOurs() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let holder = try PortHolder()
        defer { holder.close() }
        try usePort(holder.port, in: paths)

        let store = ManagedServerRecordStore(paths: paths)
        try store.save(
            .intent(
                endpoint: holder.endpoint,
                binaryPath: fixtures.missingPath(named: "kv-server").path,
                startedAt: Date()
            )
        )

        let script = try await fixtures.launchableScript(named: "kv-server", body: FixtureScript.sleepsForever)
        let controller = ManagedServerController(paths: paths, resolver: resolver(script), timeouts: timeouts)
        let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }

        #expect(error == .portInUse(holder.endpoint))
        #expect(holder.isStillListening)
        #expect(!FileManager.default.fileExists(atPath: script.path + ".pid"))
        #expect(store.load() == nil)
    }

    // Releasing the controller must not release its server.
    @Test func terminatesItsServerWhenTheControllerIsReleased() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let server = try pongServer()
        defer { server.stop() }

        let stranger = try await launchStranger(fixtures)
        let pid = stranger.processIdentifier
        defer { kill(pid, SIGKILL) }
        let identity = try #require(ProcessIdentity.startTime(of: pid))

        try usePort(server.port, in: paths)
        try ManagedServerRecordStore(paths: paths).save(record(pid: pid, identity: identity, port: server.port))

        var controller: ManagedServerController? = ManagedServerController(
            paths: paths,
            resolver: resolver(nil),
            timeouts: timeouts
        )
        #expect(try await controller?.start() == pid)
        controller = nil

        try await waitUntilGone(pid: pid)
        #expect(!ProcessIdentity.isPIDInUse(pid))
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

    // A process that outlives SIGKILL must not be forgotten: its record is the only way back to it.
    @Test func keepsTheRecordWhenTerminationDoesNotTake() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let server = try pongServer()
        defer { server.stop() }

        let script = try await fixtures.launchableScript(named: "stubborn", body: FixtureScript.ignoresTermination)
        let stubborn = Process()
        stubborn.executableURL = script
        stubborn.standardOutput = FileHandle.nullDevice
        stubborn.standardError = FileHandle.nullDevice
        try stubborn.run()
        let pid = stubborn.processIdentifier
        defer { kill(pid, SIGKILL) }
        try await fixtures.waitUntilReady(script)
        let identity = try #require(ProcessIdentity.startTime(of: pid))

        try usePort(server.port, in: paths)
        let store = ManagedServerRecordStore(paths: paths)
        try store.save(record(pid: pid, identity: identity, port: server.port))

        var impatient = timeouts
        impatient.gracefulShutdown = .zero
        impatient.forcedShutdown = .zero
        let controller = ManagedServerController(paths: paths, resolver: resolver(nil), timeouts: impatient)
        #expect(try await controller.start() == pid)

        await controller.stop()

        guard case .failed(let message) = await controller.state else {
            Issue.record("expected failed state, got \(await controller.state)")
            return
        }
        #expect(message.contains(String(pid)))
        #expect(try #require(store.load()).pid == pid)
    }

    @Test func stopKeepsARecordThisControllerNeverTookOwnershipOf() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }

        let script = try await fixtures.launchableScript(named: "stubborn", body: FixtureScript.ignoresTermination)
        let stubborn = Process()
        stubborn.executableURL = script
        stubborn.standardOutput = FileHandle.nullDevice
        stubborn.standardError = FileHandle.nullDevice
        try stubborn.run()
        let pid = stubborn.processIdentifier
        defer { kill(pid, SIGKILL) }
        try await fixtures.waitUntilReady(script)
        let identity = try #require(ProcessIdentity.startTime(of: pid))

        let port = try KVServerProcess.allocatePort()
        try usePort(port, in: paths)
        let store = ManagedServerRecordStore(paths: paths)
        try store.save(record(pid: pid, identity: identity, port: port))

        var impatient = timeouts
        impatient.gracefulShutdown = .zero
        impatient.forcedShutdown = .zero
        let controller = ManagedServerController(paths: paths, resolver: resolver(nil), timeouts: impatient)

        let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }
        #expect(error == .terminationFailed(pid))
        #expect(try #require(store.load()).pid == pid)

        await controller.stop()

        #expect(try #require(store.load()).pid == pid)
    }

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
        try await waitUntilGone(pid: pid)
        #expect(!ProcessIdentity.isPIDInUse(pid))
        #expect(ManagedServerRecordStore(paths: paths).load() == nil)
        _ = await #expect(throws: (any Error).self) { try await starting.value }
    }
}
