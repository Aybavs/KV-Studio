import Testing
import Foundation
@testable import KV_Studio

@Suite struct ValuePresentationHexParseTests {
    @Test func parsesEmptyHex() throws {
        let data = try ValuePresentation.data(fromHex: "")
        #expect(data == Data())
        let ws = try ValuePresentation.data(fromHex: "   \n\t  ")
        #expect(ws == Data())
    }

    @Test func parsesSimpleHex() throws {
        let data = try ValuePresentation.data(fromHex: "00 ff 0a 1B")
        #expect(data == Data([0x00, 0xFF, 0x0A, 0x1B]))
    }

    @Test func parsesWithoutSpaces() throws {
        let data = try ValuePresentation.data(fromHex: "48656c6c6f")
        #expect(data == Data("Hello".utf8))
    }

    @Test func parsesMixedCaseWithWhitespace() throws {
        let data = try ValuePresentation.data(fromHex: "  Aa Bb\t\ncc DD  ")
        #expect(data == Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }

    @Test func rejectsOddLength() {
        #expect(throws: ValuePresentation.HexParseError.oddLength) {
            _ = try ValuePresentation.data(fromHex: "abc")
        }
        #expect(throws: ValuePresentation.HexParseError.oddLength) {
            _ = try ValuePresentation.data(fromHex: "0 1 2")
        }
        #expect(throws: ValuePresentation.HexParseError.oddLength) {
            _ = try ValuePresentation.data(fromHex: "00 ff f")
        }
    }

    @Test func rejectsInvalidCharacter() {
        #expect(throws: ValuePresentation.HexParseError.invalidCharacter) {
            _ = try ValuePresentation.data(fromHex: "zz")
        }
        #expect(throws: ValuePresentation.HexParseError.invalidCharacter) {
            _ = try ValuePresentation.data(fromHex: "00 gg")
        }
        #expect(throws: ValuePresentation.HexParseError.invalidCharacter) {
            _ = try ValuePresentation.data(fromHex: "0x00")
        }
    }

    @Test func hexRoundTrip() throws {
        let original = Data([0x00, 0xFF, 0xFE, 0x0A, 0x0D, 0x41])
        let hex = ValuePresentation.hexString(from: original)
        let parsed = try ValuePresentation.data(fromHex: hex)
        #expect(parsed == original)
    }
}

@Suite struct BrowserNewKeyExpiryTests {
    @Test func secondsConversion() {
        #expect(NewKeyExpiry.seconds(10).asSetExpiration == .seconds(10))
    }
    @Test func minutesConversion() {
        #expect(NewKeyExpiry.minutes(2).asSetExpiration == .seconds(120))
    }
    @Test func hoursConversion() {
        #expect(NewKeyExpiry.hours(1).asSetExpiration == .seconds(3600))
    }
    @Test func noneHasNoExpiration() {
        #expect(NewKeyExpiry.none.asSetExpiration == nil)
    }
    @Test func expiryParsingValid() {
        #expect(NewKeyExpiry.from(amountText: "30", unit: .seconds)?.asSetExpiration == .seconds(30))
        #expect(NewKeyExpiry.from(amountText: "5", unit: .minutes)?.asSetExpiration == .seconds(300))
        #expect(NewKeyExpiry.from(amountText: "2", unit: .hours)?.asSetExpiration == .seconds(7200))
    }
    @Test func expiryParsingRejectsEmptyAndInvalid() {
        #expect(NewKeyExpiry.from(amountText: "", unit: .seconds) == nil)
        #expect(NewKeyExpiry.from(amountText: "abc", unit: .seconds) == nil)
        #expect(NewKeyExpiry.from(amountText: "-5", unit: .seconds) == nil)
        #expect(NewKeyExpiry.from(amountText: "0", unit: .seconds) == nil)
        #expect(NewKeyExpiry.from(amountText: "30", unit: .none) == nil || NewKeyExpiry.from(amountText: "30", unit: .none)?.asSetExpiration == nil)
    }
}

@Suite
@MainActor
struct BrowserViewModelCreateKeyTests {
    private func makeClient(to server: FakeServer) async throws -> KVClient {
        let conn = KVConnection()
        try await conn.connect(to: ConnectionEndpoint(host: "127.0.0.1", port: server.port))
        return KVClient(connection: conn)
    }
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func createKeySendsSetAndUpdatesListAndDBSize() async throws {
        let key = bytes("newkey")
        let value = bytes("newvalue")
        let setBox = LockedBox<[Data]?>(nil)
        let dbsizeBox = LockedBox<Int>(0)
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "SET" {
                    setBox.set(cmd)
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "DBSIZE" {
                    dbsizeBox.set(7)
                    peer.write(Data(":7\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        // preload some keys
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [bytes("old")]), generation: g)
        try await vm.createKey(key: key, value: value, expiration: nil, using: client)
        #expect(setBox.get() == [bytes("SET"), key, value])
        #expect(vm.keys.contains(key))
        #expect(vm.selection == key)
        #expect(vm.dbsize == 7)
    }

    @Test func createKeyWithExpirySecondsSendsEX() async throws {
        let key = bytes("k1")
        let value = bytes("v1")
        let setBox = LockedBox<[Data]?>(nil)
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "SET" {
                    setBox.set(cmd)
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "DBSIZE" {
                    peer.write(Data(":1\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        try await vm.createKey(key: key, value: value, expiration: .seconds(60), using: client)
        #expect(setBox.get() == [bytes("SET"), key, value, bytes("EX"), bytes("60")])
    }

    @Test func createKeyWithMinutesConvertedToSeconds() async throws {
        let key = bytes("k2")
        let value = bytes("v2")
        let setBox = LockedBox<[Data]?>(nil)
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "SET" {
                    setBox.set(cmd)
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "DBSIZE" {
                    peer.write(Data(":1\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let expiry = NewKeyExpiry.minutes(2).asSetExpiration
        try await vm.createKey(key: key, value: value, expiration: expiry, using: client)
        #expect(setBox.get() == [bytes("SET"), key, value, bytes("EX"), bytes("120")])
    }

    @Test func createKeyWithHoursConvertedToSeconds() async throws {
        let key = bytes("k3")
        let value = Data([0x00, 0xFF])
        let setBox = LockedBox<[Data]?>(nil)
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "SET" {
                    setBox.set(cmd)
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "DBSIZE" {
                    peer.write(Data(":1\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let expiry = NewKeyExpiry.hours(3).asSetExpiration
        try await vm.createKey(key: key, value: value, expiration: expiry, using: client)
        #expect(setBox.get() == [bytes("SET"), key, value, bytes("EX"), bytes("10800")])
    }

    @Test func createKeyRejectsEmptyKey() async throws {
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                peer.write(Data("+OK\r\n".utf8))
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        await #expect(throws: BrowserNewKeyError.emptyKey) {
            try await vm.createKey(key: Data(), value: Data("v".utf8), expiration: nil, using: client)
        }
        #expect(vm.keys.isEmpty)
    }

    @Test func createKeyAllowsEmptyValue() async throws {
        let key = bytes("kEmptyVal")
        let setBox = LockedBox<[Data]?>(nil)
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "SET" {
                    setBox.set(cmd)
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "DBSIZE" {
                    peer.write(Data(":1\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        try await vm.createKey(key: key, value: Data(), expiration: nil, using: client)
        #expect(setBox.get() == [bytes("SET"), key, Data()])
        #expect(vm.keys.contains(key))
    }

    @Test func createKeyWithBinaryHexData() async throws {
        let key = Data([0x00, 0xFF, 0x01])
        let value = Data([0xFF, 0x00, 0x02])
        let setBox = LockedBox<[Data]?>(nil)
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "SET" {
                    setBox.set(cmd)
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "DBSIZE" {
                    peer.write(Data(":1\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        try await vm.createKey(key: key, value: value, expiration: nil, using: client)
        #expect(setBox.get() == [Data("SET".utf8), key, value])
        #expect(vm.keys.contains(key))
        #expect(vm.selection == key)
    }

    @Test func createKeyDeduplicatesAndRefreshesDBSize() async throws {
        let key = bytes("dup")
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "SET" {
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "DBSIZE" {
                    peer.write(Data(":5\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [key]), generation: g)
        #expect(vm.keys.count == 1)
        try await vm.createKey(key: key, value: bytes("newval"), expiration: nil, using: client)
        #expect(vm.keys.filter { $0 == key }.count == 1, "should not duplicate existing key")
        #expect(vm.selection == key)
        #expect(vm.dbsize == 5)
    }
}

// Simple thread-safe box for capturing async values
private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); let r = value; lock.unlock(); return r }
}
