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

    private let probe = CompatibilityProbe(budget: .milliseconds(800))

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

    private func endpoint(_ server: FakeServer) -> ConnectionEndpoint {
        ConnectionEndpoint(host: "127.0.0.1", port: server.port)
    }

    private var pong: String { "+PONG\r\n" }
    private var zeroKeys: String { ":0\r\n" }
    private var emptyPage: String { "*2\r\n$1\r\n0\r\n*0\r\n" }

    // MARK: - Compatible

    @Test func compatibleServerAnswersAllThreeProbesAndReceivesExactBytes() async throws {
        let log = CommandLog()
        let server = try scriptedServer(log, replies: [pong, ":3\r\n", "*2\r\n$1\r\n0\r\n*1\r\n$3\r\nfoo\r\n"])
        defer { server.stop() }

        let outcome = try await probe.run(against: endpoint(server))

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

        let outcome = try await probe.run(against: endpoint(server))

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

        let outcome = try await probe.run(against: endpoint(server))

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

        let outcome = try await probe.run(against: endpoint(server))

        #expect(outcome == .incompatible(
            step: .ping,
            reason: .serverError(class: nil, message: "NOAUTH Authentication required")
        ))
    }

    @Test func wellFormedReplyWithTheWrongShapeIsIncompatible() async throws {
        let log = CommandLog()
        let flatPage = "*2\r\n$1\r\n0\r\n$3\r\nfoo\r\n"
        let server = try scriptedServer(log, replies: [pong, zeroKeys, flatPage])
        defer { server.stop() }

        let outcome = try await probe.run(against: endpoint(server))

        #expect(outcome == .incompatible(
            step: .scan,
            reason: .unexpectedReply(.array([.bulkString(bytes("0")), .bulkString(bytes("foo"))]))
        ))
    }

    // MARK: - Protocol failure

    @Test func repliesThatAreNotRESP2AreAProtocolFailure() async throws {
        let log = CommandLog()
        let server = try scriptedServer(log, replies: ["GARBAGE\r\n"])
        defer { server.stop() }

        let outcome = try await probe.run(against: endpoint(server))

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

        let outcome = try await probe.run(against: endpoint(server))

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

        #expect(outcome == .protocolFailure(step: .ping, reason: .timedOut(budget)))
        #expect(elapsed >= budget)
        #expect(elapsed < .seconds(2))
        #expect(holder.isStillListening)
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
        let probe = CompatibilityProbe(budget: .seconds(60))

        let task = Task { try await probe.run(against: holder.endpoint) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(holder.isStillListening)
    }

    // MARK: - Error classes

    @Test(arguments: [
        ("ERR unknown command 'DBSIZE'", ServerErrorClass.unknownCommand),
        ("ERR wrong number of arguments for 'scan' command", .wrongArgumentCount),
        ("ERR invalid cursor", .invalidCursor),
        ("ERR scan MATCH cannot change during iteration", .scanMatchChanged),
        ("ERR scan session limit reached", .scanSessionLimit),
        ("ERR server is shutting down", .shuttingDown),
        ("ERR max number of clients reached", .maxClients),
        ("ERR syntax error", .syntaxError),
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
