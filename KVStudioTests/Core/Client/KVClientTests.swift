import Testing
import Foundation
@testable import KV_Studio

@Suite(.timeLimit(.minutes(1))) struct KVClientTests {

    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }

    private func client(to server: FakeServer) async throws -> KVClient {
        let connection = KVConnection()
        try await connection.connect(to: ConnectionEndpoint(host: "127.0.0.1", port: server.port))
        return KVClient(connection: connection)
    }

    // MARK: - PING

    @Test func pingSendsExactBytesAndSucceedsOnPong() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [self.bytes("PING")])
            peer.write(self.bytes("+PONG\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        try await client.ping()
    }

    // MARK: - DBSIZE

    @Test func dbSizeParsesInteger() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [self.bytes("DBSIZE")])
            peer.write(self.bytes(":42\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        #expect(try await client.dbSize() == 42)
    }

    // MARK: - GET

    @Test func getReturnsValueOnHit() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [self.bytes("GET"), self.bytes("key")])
            peer.write(self.bytes("$5\r\nhello\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        #expect(try await client.get(bytes("key")) == bytes("hello"))
    }

    @Test func getReturnsNilOnNullBulkNotEmptyData() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes("$-1\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        #expect(try await client.get(bytes("missing")) == nil)
    }

    @Test func getReturnsEmptyDataDistinctFromNil() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes("$0\r\n\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        let value = try await client.get(bytes("empty"))
        #expect(value == Data())
        #expect(value != nil)
    }

    // MARK: - SET

    @Test func setWithNoExpirationSendsThreeArguments() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [self.bytes("SET"), self.bytes("key"), self.bytes("value")])
            peer.write(self.bytes("+OK\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        try await client.set(key: bytes("key"), value: bytes("value"), expiration: nil)
    }

    @Test func setWithSecondsAppendsEX() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [
                self.bytes("SET"), self.bytes("key"), self.bytes("value"),
                self.bytes("EX"), self.bytes("30")
            ])
            peer.write(self.bytes("+OK\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        try await client.set(key: bytes("key"), value: bytes("value"), expiration: .seconds(30))
    }

    @Test func setWithMillisecondsAppendsPX() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [
                self.bytes("SET"), self.bytes("key"), self.bytes("value"),
                self.bytes("PX"), self.bytes("1500")
            ])
            peer.write(self.bytes("+OK\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        try await client.set(key: bytes("key"), value: bytes("value"), expiration: .milliseconds(1500))
    }

    // MARK: - DEL

    @Test func deleteSendsAllKeysAndParsesCount() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [self.bytes("DEL"), self.bytes("a"), self.bytes("b")])
            peer.write(self.bytes(":2\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        #expect(try await client.delete([bytes("a"), bytes("b")]) == 2)
    }

    // MARK: - TTL

    @Test func ttlMissingKeyIsMinusTwo() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [self.bytes("TTL"), self.bytes("key")])
            peer.write(self.bytes(":-2\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        #expect(try await client.ttl(bytes("key")) == .missing)
    }

    @Test func ttlPersistentKeyIsMinusOne() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes(":-1\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        #expect(try await client.ttl(bytes("key")) == .persistent)
    }

    @Test func ttlExpiringKeyCarriesRemainingSeconds() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes(":17\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        #expect(try await client.ttl(bytes("key")) == .expiring(seconds: 17))
    }

    // MARK: - PERSIST

    @Test func persistRemovedATTL() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [self.bytes("PERSIST"), self.bytes("key")])
            peer.write(self.bytes(":1\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        #expect(try await client.persist(bytes("key")) == true)
    }

    @Test func persistDidNothing() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes(":0\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        #expect(try await client.persist(bytes("key")) == false)
    }

    // MARK: - SCAN

    @Test func scanSendsCursorMatchAndCount() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [
                self.bytes("SCAN"), self.bytes("0"),
                self.bytes("MATCH"), self.bytes("user:*"),
                self.bytes("COUNT"), self.bytes("10")
            ])
            peer.write(self.bytes("*2\r\n$1\r\n0\r\n*1\r\n$4\r\nkey1\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        let page = try await client.scan(cursor: 0, match: bytes("user:*"), count: 10)
        #expect(page == ScanPage(nextCursor: 0, keys: [bytes("key1")]))
    }

    @Test func scanOmitsMatchWhenNil() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [self.bytes("SCAN"), self.bytes("0"), self.bytes("COUNT"), self.bytes("10")])
            peer.write(self.bytes("*2\r\n$1\r\n0\r\n*0\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        _ = try await client.scan(cursor: 0, match: nil, count: 10)
    }

    @Test func scanParsesMultiDigitCursor() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes("*2\r\n$4\r\n1042\r\n*0\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        let page = try await client.scan(cursor: 0, match: nil, count: 10)
        #expect(page == ScanPage(nextCursor: 1042, keys: []))
    }

    @Test func scanCanReturnZeroKeysWithNonzeroCursor() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes("*2\r\n$2\r\n99\r\n*0\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        let page = try await client.scan(cursor: 0, match: nil, count: 10)
        #expect(page == ScanPage(nextCursor: 99, keys: []))
    }

    // MARK: - Binary safety

    @Test func binaryKeyAndValueSurviveRoundTripByteForByte() async throws {
        let key = Data([0x00, 0x0D, 0x0A, 0x41, 0x00])
        let value = Data([0xFF, 0x0D, 0x0A, 0x00, 0x42, 0x0D, 0x0A])

        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [self.bytes("SET"), key, value])
            peer.write(self.bytes("+OK\r\n"))

            let getCommand = peer.readCommand()
            #expect(getCommand == [self.bytes("GET"), key])
            peer.write(Data("$\(value.count)\r\n".utf8) + value + Data("\r\n".utf8))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        try await client.set(key: key, value: value, expiration: nil)
        let roundTripped = try await client.get(key)
        #expect(roundTripped == value)
    }

    // MARK: - Errors

    @Test func typedCommandThrowsOnServerError() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes("-ERR wrong number of arguments\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        await #expect(throws: KVClientError.serverError(bytes("ERR wrong number of arguments"))) {
            _ = try await client.get(self.bytes("key"))
        }
    }

    @Test func rawReturnsErrorReplyInsteadOfThrowing() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes("-ERR unknown command\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        let reply = try await client.raw([bytes("BOGUS")])
        #expect(reply == .error(bytes("ERR unknown command")))
    }

    @Test func rawReturnsReplyUnchangedOnSuccess() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [self.bytes("PING")])
            peer.write(self.bytes("+PONG\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        let reply = try await client.raw([bytes("PING")])
        #expect(reply == .simpleString(bytes("PONG")))
    }

    @Test func wrongShapedReplyThrowsUnexpectedReplyRatherThanCoercing() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes("+PONG\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        await #expect(throws: KVClientError.unexpectedReply(.simpleString(bytes("PONG")))) {
            _ = try await client.dbSize()
        }
    }

    @Test func scanWithWrongElementCountThrowsUnexpectedReply() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes(":0\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        await #expect(throws: KVClientError.self) {
            _ = try await client.scan(cursor: 0, match: nil, count: 10)
        }
    }

    // MARK: - VERSION

    @Test func serverVersionReadsTheBulkReply() async throws {
        let server = try FakeServer { peer in
            let command = peer.readCommand()
            #expect(command == [self.bytes("VERSION")])
            peer.write(self.bytes("$5\r\n1.2.0\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        #expect(try await client.serverVersion() == "1.2.0")
    }

    // A server that does not know the command has answered the question: it is older than 1.2.
    @Test func serverVersionIsNilWhenTheCommandIsUnknown() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes("-ERR unknown command 'VERSION'\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        #expect(try await client.serverVersion() == nil)
    }

    @Test func serverVersionRejectsAReplyThatIsNeitherAVersionNorARefusal() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(self.bytes(":7\r\n"))
        }
        defer { server.stop() }

        let client = try await client(to: server)
        await #expect(throws: KVClientError.self) { try await client.serverVersion() }
    }
}
