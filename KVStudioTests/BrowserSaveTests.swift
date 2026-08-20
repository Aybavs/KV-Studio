import Testing
import Foundation
@testable import KV_Studio

private final class CommandBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [[Data]] = []
    func append(_ cmd: [Data]) { lock.lock(); value.append(cmd); lock.unlock() }
    var count: Int { lock.lock(); let c = value.count; lock.unlock(); return c }
    var first: [Data]? { lock.lock(); let f = value.first; lock.unlock(); return f }
    var isEmpty: Bool { lock.lock(); let e = value.isEmpty; lock.unlock(); return e }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0
    func increment() -> Int { lock.lock(); v += 1; let r = v; lock.unlock(); return r }
    var value: Int { lock.lock(); let r = v; lock.unlock(); return r }
}

private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    func get() -> Bool { lock.lock(); let r = v; lock.unlock(); return r }
    func set(_ b: Bool) { lock.lock(); v = b; lock.unlock() }
}

@Suite
@MainActor
struct BrowserSavePreserveTTLDefaultTests {
    @Test func preserveTrueOnlyWhenExpiring() {
        let vm = BrowserViewModel()
        let key = Data("k".utf8)
        let g = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: Data("v".utf8), ttl: .expiring(seconds: 42), key: key, generation: g)
        #expect(vm.preserveTTL == true)
        let g2 = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: Data("v".utf8), ttl: .persistent, key: key, generation: g2)
        #expect(vm.preserveTTL == false)
        let g3 = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: Data("v".utf8), ttl: .missing, key: key, generation: g3)
        #expect(vm.preserveTTL == false)
        let g4 = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: Data("v".utf8), ttl: .expiring(seconds: 1), key: key, generation: g4)
        #expect(vm.preserveTTL == true)
    }

    @Test func resetClearsPreserve() {
        let vm = BrowserViewModel()
        let key = Data("k".utf8)
        let g = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: Data("v".utf8), ttl: .expiring(seconds: 10), key: key, generation: g)
        #expect(vm.preserveTTL == true)
        vm.reset()
        #expect(vm.preserveTTL == false)
    }

    @Test func prepareLoadResetsPreserve() {
        let vm = BrowserViewModel()
        let key = Data("k".utf8)
        let g = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: Data("v".utf8), ttl: .expiring(seconds: 5), key: key, generation: g)
        #expect(vm.preserveTTL == true)
        _ = vm.prepareDetailLoad(for: Data("k2".utf8))
        #expect(vm.preserveTTL == false)
    }
}

@Suite
@MainActor
struct BrowserSaveTTLsTests {
    private func makeClient(to server: FakeServer) async throws -> KVClient {
        let conn = KVConnection()
        try await conn.connect(to: ConnectionEndpoint(host: "127.0.0.1", port: server.port))
        return KVClient(connection: conn)
    }

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func expiringKeyPreservedWithEX() async throws {
        let key = bytes("mykey")
        let newValue = bytes("newval")
        let setBox = CommandBox()
        let ttlCounter = CounterBox()

        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "TTL" {
                    _ = ttlCounter.increment()
                    peer.write(Data(":77\r\n".utf8))
                } else if name == "SET" {
                    setBox.append(cmd)
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "GET" {
                    peer.write(Data("$\(newValue.count)\r\n".utf8) + newValue + Data("\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let g = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: bytes("old"), ttl: .expiring(seconds: 100), key: key, generation: g)
        #expect(vm.preserveTTL == true)
        vm.preserveTTL = true
        await vm.save(value: newValue, using: client)
        #expect(setBox.count == 1)
        #expect(setBox.first == [bytes("SET"), key, newValue, bytes("EX"), bytes("77")])
        if case .loaded(let k, let v, let ttl) = vm.detailState {
            #expect(k == key)
            #expect(v == newValue)
            #expect(ttl == .expiring(seconds: 77))
        } else {
            Issue.record("expected loaded after save, got \(vm.detailState)")
        }
    }

    @Test func persistentKeyStaysPersistentWhenPreserveOn() async throws {
        let key = bytes("k1")
        let newValue = bytes("nv")
        let setBox = CommandBox()
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "TTL" {
                    peer.write(Data(":-1\r\n".utf8))
                } else if name == "SET" {
                    setBox.append(cmd)
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "GET" {
                    peer.write(Data("$\(newValue.count)\r\n".utf8) + newValue + Data("\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let g = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: bytes("old"), ttl: .persistent, key: key, generation: g)
        vm.preserveTTL = true
        await vm.save(value: newValue, using: client)
        #expect(setBox.count == 1)
        #expect(setBox.first == [bytes("SET"), key, newValue])
        if case .loaded(_, _, let ttl) = vm.detailState {
            #expect(ttl == .persistent)
        } else {
            Issue.record("expected loaded persistent")
        }
    }

    @Test func preserveOffClearsExpiry() async throws {
        let key = bytes("k2")
        let newValue = bytes("new2")
        let setBox = CommandBox()
        let ttlFirst = BoolBox(true)
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "TTL" {
                    if ttlFirst.get() {
                        ttlFirst.set(false)
                        peer.write(Data(":55\r\n".utf8))
                    } else {
                        peer.write(Data(":-1\r\n".utf8))
                    }
                } else if name == "SET" {
                    setBox.append(cmd)
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "GET" {
                    peer.write(Data("$\(newValue.count)\r\n".utf8) + newValue + Data("\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let g = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: bytes("old"), ttl: .expiring(seconds: 55), key: key, generation: g)
        vm.preserveTTL = false
        await vm.save(value: newValue, using: client)
        #expect(setBox.count == 1)
        #expect(setBox.first == [bytes("SET"), key, newValue], "preserve off must not send EX")
        if case .loaded(_, _, let ttl) = vm.detailState {
            #expect(ttl == .persistent, "after clearing expiry, refresh should be persistent")
        } else {
            Issue.record("expected loaded")
        }
    }

    @Test func keyDisappearsBeforeSaveDoesNotRecreate() async throws {
        let key = bytes("vanish")
        let newValue = bytes("shouldNotSave")
        let setBox = CommandBox()
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "TTL" {
                    peer.write(Data(":-2\r\n".utf8))
                } else if name == "SET" {
                    setBox.append(cmd)
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "GET" {
                    peer.write(Data("$-1\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let g = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: bytes("old"), ttl: .expiring(seconds: 10), key: key, generation: g)
        vm.preserveTTL = true
        await vm.save(value: newValue, using: client)
        #expect(setBox.isEmpty, "must not call SET when TTL is -2")
        #expect(vm.detailState == .missing(key: key))
    }

    @Test func ttlZeroDuringEditingShowsConflictAndDoesNotSet() async throws {
        let key = bytes("zero")
        let newValue = bytes("new")
        let setBox = CommandBox()
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "TTL" {
                    peer.write(Data(":0\r\n".utf8))
                } else if name == "SET" {
                    setBox.append(cmd)
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "GET" {
                    peer.write(Data("$-1\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let g = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: bytes("old"), ttl: .expiring(seconds: 5), key: key, generation: g)
        vm.preserveTTL = true
        await vm.save(value: newValue, using: client)
        #expect(setBox.isEmpty, "must not SET when TTL is 0")
        if case .failed(let k, let msg) = vm.detailState {
            #expect(k == key)
            let lower = msg.lowercased()
            #expect(lower.contains("expir") || lower.contains("no longer") || lower.contains("conflict") || lower.contains("expired"))
        } else {
            Issue.record("expected failed with conflict message, got \(vm.detailState)")
        }
    }

    @Test func binaryKeyAndValuePreservedWithTTL() async throws {
        let key = Data([0x00, 0xFF, 0x01])
        let newValue = Data([0xFF, 0x00, 0x02, 0x03])
        let setBox = CommandBox()
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "TTL" {
                    peer.write(Data(":33\r\n".utf8))
                } else if name == "SET" {
                    setBox.append(cmd)
                    peer.write(Data("+OK\r\n".utf8))
                } else if name == "GET" {
                    var header = Data("$\(newValue.count)\r\n".utf8)
                    header.append(newValue)
                    header.append(Data("\r\n".utf8))
                    peer.write(header)
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let g = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: Data([0x01]), ttl: .expiring(seconds: 50), key: key, generation: g)
        vm.preserveTTL = true
        await vm.save(value: newValue, using: client)
        #expect(setBox.count == 1)
        #expect(setBox.first == [Data("SET".utf8), key, newValue, Data("EX".utf8), Data("33".utf8)])
        if case .loaded(let k, let v, _) = vm.detailState {
            #expect(k == key)
            #expect(v == newValue)
        } else {
            Issue.record("expected loaded binary")
        }
    }
}
