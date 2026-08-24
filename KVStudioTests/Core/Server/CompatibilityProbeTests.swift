import Testing
import Foundation
@testable import KV_Studio

private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[Data]] = []

    func record(_ command: [Data]) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    var recorded: [[Data]] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CompatibilityProbeTests {

    // The production default, so these exercise the real budget rather than one tuned to whichever
    // machine happens to run them.
    private let probe = CompatibilityProbe(budget: .seconds(5))

    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }

    private func scriptedServer(_ log: CommandLog, replies: [String]) throws -> FakeServer {
        try FakeServer { peer in
            for reply in replies {
                guard let command = peer.readCommand() else { return }
                log.record(command)
                peer.write(Data(reply.utf8))
            }
        }
    }

    private var pong: String { "+PONG\r\n" }
    private var zeroKeys: String { ":0\r\n" }
    private var emptyPage: String { "*2\r\n$1\r\n0\r\n*0\r\n" }

    // MARK: - Compatible

    @Test func compatibleServerAnswersAllThreeProbesAndReceivesExactBytes() async throws {
        let log = CommandLog()
        let server = try scriptedServer(log, replies: [pong, ":3\r\n", "*2\r\n$1\r\n0\r\n*1\r\n$3\r\nfoo\r\n"])
        defer { server.stop() }

        let outcome = try await probe.run(against: server.endpoint)

        #expect(outcome == .compatible)
        #expect(log.recorded == [
            [bytes("PING")],
            [bytes("DBSIZE")],
            [bytes("SCAN"), bytes("0"), bytes("COUNT"), bytes("1")]
        ])
    }

    // MARK: - Connected but incompatible

    @Test func oldBackendThatRejectsDBSIZEIsIncompatibleAndIsNeverAskedToSCAN() async throws {
        let log = CommandLog()
        let server = try scriptedServer(log, replies: [pong, "-ERR unknown command 'DBSIZE'\r\n", emptyPage])
        defer { server.stop() }

        let outcome = try await probe.run(against: server.endpoint)

        #expect(outcome == .incompatible(
            step: .dbSize,
            reason: .serverError(class: .unknownCommand, message: "ERR unknown command 'DBSIZE'")
        ))
        #expect(log.recorded == [[bytes("PING")], [bytes("DBSIZE")]])
    }

    @Test func rejectedScanIsIncompatible() async throws {
        let log = CommandLog()
        let server = try scriptedServer(log, replies: [pong, zeroKeys, "-ERR invalid cursor\r\n"])
        defer { server.stop() }

        let outcome = try await probe.run(against: server.endpoint)

        #expect(outcome == .incompatible(
            step: .scan,
            reason: .serverError(class: .invalidCursor, message: "ERR invalid cursor")
        ))
        #expect(log.recorded.count == 3)
    }

    @Test func unrecognisedServerErrorIsStillIncompatibleAndCarriesItsMessage() async throws {
        let log = CommandLog()
        let server = try scriptedServer(log, replies: ["-NOAUTH Authentication required\r\n"])
        defer { server.stop() }

        let outcome = try await probe.run(against: server.endpoint)

        #expect(outcome == .incompatible(
            step: .ping,
            reason: .serverError(class: nil, message: "NOAUTH Authentication required")
        ))
    }

    @Test(arguments: [
        ([":1\r\n"], ProbeStep.ping, RESPValue.integer(1)),
        (["+PONG\r\n", "+OK\r\n"], .dbSize, .simpleString(Data("OK".utf8))),
        (["+PONG\r\n", ":0\r\n", "*2\r\n$1\r\n0\r\n$3\r\nfoo\r\n"], .scan,
         .array([.bulkString(Data("0".utf8)), .bulkString(Data("foo".utf8))]))
    ])
    func wellFormedRepliesWithTheWrongShapeAreIncompatible(
        replies: [String],
        step: ProbeStep,
        reply: RESPValue
    ) async throws {
        let log = CommandLog()
        let server = try scriptedServer(log, replies: replies)
        defer { server.stop() }

        let outcome = try await probe.run(against: server.endpoint)

        #expect(outcome == .incompatible(step: step, reason: .unexpectedReply(reply)))
    }

    // MARK: - Protocol failure

    @Test func repliesThatAreNotRESP2AreAProtocolFailure() async throws {
        let log = CommandLog()
        let server = try scriptedServer(log, replies: ["GARBAGE\r\n"])
        defer { server.stop() }

        let outcome = try await probe.run(against: server.endpoint)

        #expect(outcome == .protocolFailure(
            step: .ping,
            reason: .malformedReply(.unknownTypeByte(UInt8(ascii: "G")))
        ))
    }

    @Test func aConnectionClosedMidExchangeIsAProtocolFailure() async throws {
        let log = CommandLog()
        let server = try FakeServer { peer in
            guard let command = peer.readCommand() else { return }
            log.record(command)
        }
        defer { server.stop() }

        let outcome = try await probe.run(against: server.endpoint)

        #expect(outcome == .protocolFailure(step: .ping, reason: .connectionClosed))
        #expect(log.recorded == [[bytes("PING")]])
    }

    @Test func aPeerThatNeverRepliesIsBoundedByTheBudget() async throws {
        let holder = try PortHolder()
        defer { holder.close() }
        let budget = Duration.milliseconds(300)
        let probe = CompatibilityProbe(budget: budget)

        let started = ContinuousClock.now
        let outcome = try await probe.run(against: holder.endpoint)
        let elapsed = ContinuousClock.now - started

        // Which step the budget expires on depends on how fast the connect completes, so it is
        // not pinned here; the point is that a silent peer times out instead of hanging.
        guard case .unreachable(.timedOut(_, let reported)) = outcome else {
            Issue.record("expected a bounded timeout, got \(outcome)")
            return
        }
        #expect(reported == budget)
        #expect(elapsed >= budget)
        #expect(elapsed < .seconds(15))
        #expect(holder.acceptedPeerHungUp(within: .seconds(2)))
    }

    @Test func aServerThatFallsSilentMidProbeIsUnreachableNotAProtocolFailure() async throws {
        let log = CommandLog()
        let release = DispatchSemaphore(value: 0)
        let server = try FakeServer { peer in
            for reply in [self.pong, self.zeroKeys] {
                guard let command = peer.readCommand() else { return }
                log.record(command)
                peer.write(Data(reply.utf8))
            }
            guard let silenced = peer.readCommand() else { return }
            log.record(silenced)
            release.wait()
        }
        defer {
            release.signal()
            server.stop()
        }
        // Generous enough that PING and DBSIZE still complete under load, because this test's
        // whole point is that the budget expires ON scan, after two commands got through.
        let budget = Duration.seconds(5)
        let probe = CompatibilityProbe(budget: budget)

        let started = ContinuousClock.now
        let outcome = try await probe.run(against: server.endpoint)
        let elapsed = ContinuousClock.now - started

        #expect(outcome == .unreachable(.timedOut(step: .scan, budget: budget)))
        #expect(elapsed >= budget)
        #expect(elapsed < .seconds(20))
        #expect(log.recorded.count == 3)
    }

    // MARK: - Unreachable

    @Test func nothingListeningIsUnreachable() async throws {
        let port = try KVServerProcess.allocatePort()

        let outcome = try await probe.run(against: ConnectionEndpoint(host: "127.0.0.1", port: port))

        guard case .unreachable(.connectFailed) = outcome else {
            Issue.record("expected an unreachable outcome, got \(outcome)")
            return
        }
    }

    @Test func portZeroIsUnreachable() async throws {
        let outcome = try await probe.run(against: ConnectionEndpoint(host: "127.0.0.1", port: 0))

        #expect(outcome == .unreachable(.invalidPort(0)))
    }

    // MARK: - Cancellation

    @Test func cancellationUnparksTheProbeAndIsReportedAsCancellation() async throws {
        let holder = try PortHolder()
        defer { holder.close() }
        // A budget it cannot reach, so returning at all can only be cancellation.
        let probe = CompatibilityProbe(budget: .seconds(60))

        let task = Task { try await probe.run(against: holder.endpoint) }
        try await Task.sleep(for: .milliseconds(150))
        let cancelled = ContinuousClock.now
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        // Unwinding the socket takes seconds on a loaded machine; what this pins is that the probe
        // did not sit out its budget, not how fast the teardown happened to be.
        #expect(ContinuousClock.now - cancelled < .seconds(20))
    }

    // MARK: - Error classes

    @Test(arguments: [
        ("ERR unknown command 'DBSIZE'", ServerErrorClass.unknownCommand),
        ("ERR wrong number of arguments for 'scan' command", .wrongArgumentCount),
        ("ERR invalid cursor 'abc'", .invalidCursor),
        ("ERR scan MATCH cannot change during iteration", .scanMatchChanged),
        ("ERR scan session limit reached (64)", .scanSessionLimit),
        ("ERR server is shutting down, retry later", .shuttingDown),
        ("ERR max number of clients reached", .maxClients),
        ("ERR syntax error near 'COUNT'", .syntaxError),
        ("ERR Protocol error: invalid multibulk length", .protocolError)
    ])
    func classifiesDocumentedErrorPrefixes(message: String, expected: ServerErrorClass) {
        #expect(ServerErrorClass(message: message) == expected)
    }

    @Test func doesNotClassifyUndocumentedErrors() {
        #expect(ServerErrorClass(message: "ERR something new") == nil)
        #expect(ServerErrorClass(message: "WRONGTYPE Operation against a key") == nil)
        #expect(ServerErrorClass(message: "") == nil)
    }
}
