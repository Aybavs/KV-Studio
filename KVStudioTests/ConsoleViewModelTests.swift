import Testing
import Foundation
@testable import KV_Studio

@Suite struct ConsoleViewModelTests {

    @Test @MainActor func emptyInputDoesNothing() async {
        let vm = ConsoleViewModel()
        vm.input = "   "
        await vm.submit(using: nil as KVClient?)
        #expect(vm.entries.isEmpty)
        #expect(vm.history.isEmpty)
    }

    @Test @MainActor func unterminatedQuoteProducesLocalError() async {
        let vm = ConsoleViewModel()
        vm.input = "SET key \"hello"
        await vm.submit(using: nil as KVClient?)
        #expect(vm.entries.count == 1)
        #expect(vm.entries.first?.response == .localError("Parse error: unterminated quote"))
        #expect(vm.history == ["SET key \"hello"])
    }

    @Test @MainActor func notConnectedProducesLocalError() async {
        let vm = ConsoleViewModel()
        vm.input = "PING"
        await vm.submit(using: nil as KVClient?)
        #expect(vm.entries.count == 1)
        if case .localError(let msg) = vm.entries.first?.response {
            #expect(msg == "Not connected to a server.")
        } else {
            Issue.record("expected localError")
        }
    }

    @Test @MainActor func clearRemovesEntriesButKeepsHistory() async {
        let vm = ConsoleViewModel()
        vm.input = "PING"
        await vm.submit(using: nil as KVClient?)
        #expect(!vm.entries.isEmpty)
        let hist = vm.history
        vm.clear()
        #expect(vm.entries.isEmpty)
        #expect(vm.history == hist)
        #expect(vm.canClear == false)
    }

    @Test @MainActor func historyNavigationUpDown() {
        let vm = ConsoleViewModel()
        vm._appendHistory("PING")
        vm.input = ""
        vm._appendHistory("GET foo")
        vm.input = ""
        // Up -> GET foo
        vm.historyUp()
        #expect(vm.input == "GET foo")
        // Up again -> PING
        vm.historyUp()
        #expect(vm.input == "PING")
        // Up stays at oldest
        vm.historyUp()
        #expect(vm.input == "PING")
        // Down -> GET foo
        vm.historyDown()
        #expect(vm.input == "GET foo")
        // Down -> draft (empty)
        vm.historyDown()
        #expect(vm.input == "")
        // Down again stays
        vm.historyDown()
        #expect(vm.input == "")
    }

    @Test @MainActor func historyPreservesDraft() {
        let vm = ConsoleViewModel()
        vm._appendHistory("PING")
        vm.input = "draft"
        vm.historyUp()
        #expect(vm.input == "PING")
        vm.historyDown()
        #expect(vm.input == "draft")
    }

    @Test @MainActor func successfulRawAppendsResp() async throws {
        let server = try FakeServer { peer in
            while let cmd = peer.readCommand() {
                if cmd.first == Data("PING".utf8) {
                    peer.write(Data("+PONG\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let conn = KVConnection()
        try await conn.connect(to: server.endpoint)
        let client = KVClient(connection: conn)
        let vm = ConsoleViewModel()
        vm.input = "PING"
        await vm.submit(using: client)
        #expect(vm.entries.count == 1)
        #expect(vm.entries.first?.command == "PING")
        #expect(vm.entries.first?.response == .resp(.simpleString(Data("PONG".utf8))))
        #expect(vm.history == ["PING"])
        await conn.disconnect()
    }

    @Test @MainActor func serverErrorReplyStoredAsRespError() async throws {
        let server = try FakeServer { peer in
            while let cmd = peer.readCommand() {
                _ = cmd
                peer.write(Data("-ERR unknown command 'FOO'\r\n".utf8))
            }
        }
        defer { server.stop() }
        let conn = KVConnection()
        try await conn.connect(to: server.endpoint)
        let client = KVClient(connection: conn)
        let vm = ConsoleViewModel()
        vm.input = "FOO"
        await vm.submit(using: client)
        #expect(vm.entries.first?.response == .resp(.error(Data("ERR unknown command 'FOO'".utf8))))
        await conn.disconnect()
    }

    @Test @MainActor func transportErrorStoredAsTransportError() async throws {
        let server = try FakeServer { peer in
            while let cmd = peer.readCommand() {
                _ = cmd
                // close without reply to trigger connectionClosed
                peer.close()
                break
            }
        }
        defer { server.stop() }
        let conn = KVConnection()
        try await conn.connect(to: server.endpoint)
        let client = KVClient(connection: conn)
        let vm = ConsoleViewModel()
        vm.input = "PING"
        await vm.submit(using: client)
        if case .transportError = vm.entries.first?.response {
            // ok
        } else {
            Issue.record("expected transportError got \(String(describing: vm.entries.first?.response))")
        }
        await conn.disconnect()
    }

    @Test @MainActor func quotedCommandIsTokenizedCorrectly() async throws {
        let server = try FakeServer { peer in
            while let cmd = peer.readCommand() {
                // echo first arg as simple string
                if cmd.count >= 2 && cmd[0] == Data("GET".utf8) {
                    let key = cmd[1]
                    // reply bulk string with key
                    let prefix = "$\(key.count)\r\n".data(using: .utf8)!
                    var reply = Data()
                    reply.append(prefix)
                    reply.append(key)
                    reply.append(Data("\r\n".utf8))
                    peer.write(reply)
                } else {
                    peer.write(Data("+OK\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let conn = KVConnection()
        try await conn.connect(to: server.endpoint)
        let client = KVClient(connection: conn)
        let vm = ConsoleViewModel()
        vm.input = "GET \"my key\""
        await vm.submit(using: client)
        #expect(vm.entries.first?.response == .resp(.bulkString(Data("my key".utf8))))
        await conn.disconnect()
    }
}

@Suite struct ConsoleRESPFormattingTests {
    @Test func simpleStringFormatting() {
        #expect(ConsoleRESPFormatting.string(for: Data("OK".utf8)) == "OK")
    }

    @Test func bulkNilIsNil() {
        let v: RESPValue = .bulkString(nil)
        #expect(v == .bulkString(nil))
    }

    @Test func isServerErrorDetection() {
        #expect(ConsoleRESPFormatting.isServerError(.error(Data("ERR".utf8))) == true)
        #expect(ConsoleRESPFormatting.isServerError(.simpleString(Data("OK".utf8))) == false)
        #expect(ConsoleRESPFormatting.isServerError(.integer(1)) == false)
    }

    @Test func arrayValuesPreserved() {
        let nested: RESPValue = .array([.bulkString(Data("0".utf8)), .array([.bulkString(Data("k1".utf8)), .bulkString(Data("k2".utf8))])])
        if case .array(let elems?) = nested {
            #expect(elems.count == 2)
            if case .bulkString(let d?) = elems[0] { #expect(d == Data("0".utf8)) }
            else { Issue.record("first element mismatch") }
        } else { Issue.record("not array") }
    }

    @Test func nonUTF8FallsBackToHex() {
        let data = Data([0xFF, 0xFE])
        let str = ConsoleRESPFormatting.string(for: data)
        #expect(str == ValuePresentation.hexString(from: data))
    }
}

@Suite struct ConsoleIntegrationScanTests {
    @Test @MainActor func scanNestedArrayReply() async throws {
        let server = try FakeServer { peer in
            while let cmd = peer.readCommand() {
                if cmd.first == Data("SCAN".utf8) {
                    // *2 $1 0 *2 $2 k1 $2 k2  -- SCAN 0 -> cursor 0, keys k1 k2
                    peer.write(Data("*2\r\n$1\r\n0\r\n*2\r\n$2\r\nk1\r\n$2\r\nk2\r\n".utf8))
                } else {
                    peer.write(Data("+PONG\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let conn = KVConnection()
        try await conn.connect(to: server.endpoint)
        let client = KVClient(connection: conn)
        let vm = ConsoleViewModel()
        vm.input = "SCAN 0 COUNT 10"
        await vm.submit(using: client)
        if case .resp(let v) = vm.entries.first?.response {
            if case .array(let elems?) = v {
                #expect(elems.count == 2)
            } else { Issue.record("expected scan array") }
        } else { Issue.record("expected resp") }
        await conn.disconnect()
    }
}
