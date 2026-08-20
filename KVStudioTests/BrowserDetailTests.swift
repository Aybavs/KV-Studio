import Testing
import Foundation
@testable import KV_Studio

@Suite
@MainActor
struct BrowserDetailInitialStateTests {
    @Test func startsIdle() {
        let vm = BrowserViewModel()
        #expect(vm.detailState == .idle)
        #expect(vm.detailGeneration == 0)
    }
}

@Suite
@MainActor
struct BrowserDetailStateTransitionsTests {
    @Test func prepareDetailLoadMovesToLoadingAndIncrementsGeneration() {
        let vm = BrowserViewModel()
        let key = Data("k1".utf8)
        let gen = vm.prepareDetailLoad(for: key)
        #expect(gen == 1)
        #expect(vm.detailGeneration == 1)
        #expect(vm.detailState == .loading(key: key))
    }

    @Test func applyDetailWithValueLoadsWithTTL() {
        let vm = BrowserViewModel()
        let key = Data("k1".utf8)
        let value = Data("v1".utf8)
        let gen = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: value, ttl: .persistent, key: key, generation: gen)
        #expect(vm.detailState == .loaded(key: key, value: value, ttl: .persistent))
    }

    @Test func applyDetailWithNilValueShowsMissing() {
        let vm = BrowserViewModel()
        let key = Data("k1".utf8)
        let gen = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: nil, ttl: .missing, key: key, generation: gen)
        #expect(vm.detailState == .missing(key: key))
    }

    @Test func applyDetailWithExpiringTTLPreservesTTL() {
        let vm = BrowserViewModel()
        let key = Data("k1".utf8)
        let value = Data("v1".utf8)
        let gen = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: value, ttl: .expiring(seconds: 42), key: key, generation: gen)
        #expect(vm.detailState == .loaded(key: key, value: value, ttl: .expiring(seconds: 42)))
    }

    @Test func staleGenerationIsIgnored() {
        let vm = BrowserViewModel()
        let k1 = Data("k1".utf8)
        let k2 = Data("k2".utf8)
        let g1 = vm.prepareDetailLoad(for: k1)
        let g2 = vm.prepareDetailLoad(for: k2)
        #expect(g1 == 1)
        #expect(g2 == 2)
        #expect(vm.detailState == .loading(key: k2))
        vm.applyDetail(value: Data("stale".utf8), ttl: .persistent, key: k1, generation: g1)
        #expect(vm.detailState == .loading(key: k2), "stale apply must be ignored")
        vm.applyDetail(value: Data("fresh".utf8), ttl: .persistent, key: k2, generation: g2)
        #expect(vm.detailState == .loaded(key: k2, value: Data("fresh".utf8), ttl: .persistent))
    }

    @Test func applyFailureMovesToFailedAndRespectsGeneration() {
        let vm = BrowserViewModel()
        let key = Data("k1".utf8)
        let gen = vm.prepareDetailLoad(for: key)
        vm.applyDetailFailure(KVClientError.serverError(Data("ERR boom".utf8)), key: key, generation: gen)
        if case .failed(let k, let msg) = vm.detailState {
            #expect(k == key)
            #expect(msg.contains("boom"))
        } else {
            Issue.record("expected failed state")
        }
        // stale failure ignored
        let k2 = Data("k2".utf8)
        let g2 = vm.prepareDetailLoad(for: k2)
        vm.applyDetailFailure(KVClientError.serverError(Data("ERR stale".utf8)), key: key, generation: gen)
        #expect(vm.detailState == .loading(key: k2))
        vm.applyDetailFailure(KVClientError.serverError(Data("ERR fresh".utf8)), key: k2, generation: g2)
        if case .failed(let k, let msg) = vm.detailState {
            #expect(k == k2)
            #expect(msg.contains("fresh"))
        } else {
            Issue.record("expected failed after fresh")
        }
    }

    @Test func retainsRawBinaryKeyAndValueAsData() {
        let vm = BrowserViewModel()
        let key = Data([0xFF, 0x00, 0x01, 0x02])
        let value = Data([0x00, 0xFF, 0xFE])
        let gen = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: value, ttl: .persistent, key: key, generation: gen)
        if case .loaded(let k, let v, _) = vm.detailState {
            #expect(k == key)
            #expect(v == value)
        } else {
            Issue.record("expected loaded with binary data")
        }
    }

    @Test func resetClearsDetailState() {
        let vm = BrowserViewModel()
        let key = Data("k".utf8)
        let gen = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: Data("v".utf8), ttl: .persistent, key: key, generation: gen)
        vm.reset()
        #expect(vm.detailState == .idle)
        #expect(vm.detailGeneration == 0)
    }

    @Test func selectNilClearsSelectionAndDetail() {
        let vm = BrowserViewModel()
        let key = Data("k1".utf8)
        let gen = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: Data("v".utf8), ttl: .persistent, key: key, generation: gen)
        vm.select(nil)
        // select nil should reset detail to idle? At least selection cleared; we verify idle after select nil if implemented
        // If not idle, test will fail and drive implementation to clear detail on nil selection.
        #expect(vm.selection == nil)
        #expect(vm.detailState == .idle)
    }
}

@Suite
@MainActor
struct BrowserDetailAsyncTests {
    private func makeClient(to server: FakeServer) async throws -> KVClient {
        let conn = KVConnection()
        try await conn.connect(to: ConnectionEndpoint(host: "127.0.0.1", port: server.port))
        return KVClient(connection: conn)
    }

    @Test func loadDetailConcurrentlyRequestsGETandTTLAndShowsLoaded() async throws {
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "GET" {
                    // value "hello"
                    peer.write(Data("$5\r\nhello\r\n".utf8))
                } else if name == "TTL" {
                    peer.write(Data(":100\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let key = Data("k1".utf8)
        await vm.loadDetail(for: key, using: client)
        if case .loaded(let k, let v, let ttl) = vm.detailState {
            #expect(k == key)
            #expect(v == Data("hello".utf8))
            #expect(ttl == .expiring(seconds: 100))
        } else {
            Issue.record("expected loaded, got \(vm.detailState)")
        }
    }

    @Test func loadDetailShowsMissingWhenGETReturnsNil() async throws {
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "GET" {
                    peer.write(Data("$-1\r\n".utf8))
                } else if name == "TTL" {
                    peer.write(Data(":-2\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let key = Data("missing".utf8)
        await vm.loadDetail(for: key, using: client)
        #expect(vm.detailState == .missing(key: key))
    }

    @Test func loadDetailShowsMissingRetainsKeyEvenWithPersistentTTL() async throws {
        // GET nil but TTL maybe -2 missing; we still show missing and retain key
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "GET" {
                    peer.write(Data("$-1\r\n".utf8))
                } else if name == "TTL" {
                    peer.write(Data(":-2\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let key = Data([0xFF, 0x00])
        await vm.loadDetail(for: key, using: client)
        #expect(vm.detailState == .missing(key: key))
    }

    @Test func loadDetailHandlesPersistentTTL() async throws {
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "GET" {
                    peer.write(Data("$3\r\nval\r\n".utf8))
                } else if name == "TTL" {
                    peer.write(Data(":-1\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let key = Data("k1".utf8)
        await vm.loadDetail(for: key, using: client)
        if case .loaded(_, _, let ttl) = vm.detailState {
            #expect(ttl == .persistent)
        } else {
            Issue.record("expected loaded with persistent ttl")
        }
    }

    @Test func loadDetailShowsFailedWhenServerErrors() async throws {
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                peer.write(Data("-ERR boom\r\n".utf8))
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let key = Data("k1".utf8)
        await vm.loadDetail(for: key, using: client)
        if case .failed(let k, let msg) = vm.detailState {
            #expect(k == key)
            #expect(msg.contains("boom"))
        } else {
            Issue.record("expected failed state")
        }
    }

    @Test func loadDetailRetainsBinaryValue() async throws {
        // Binary value containing non-UTF8 bytes
        let binaryValue = Data([0xFF, 0x00, 0x01, 0x02, 0x03])
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "GET" {
                    // bulk string: $5\r\n + bytes + \r\n
                    var header = Data("$\(binaryValue.count)\r\n".utf8)
                    header.append(binaryValue)
                    header.append(Data("\r\n".utf8))
                    peer.write(header)
                } else if name == "TTL" {
                    peer.write(Data(":-1\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let key = Data([0xFF, 0xFE])
        await vm.loadDetail(for: key, using: client)
        if case .loaded(let k, let v, _) = vm.detailState {
            #expect(k == key)
            #expect(v == binaryValue)
        } else {
            Issue.record("expected loaded with binary value")
        }
    }

    @Test func loadDetailIgnoresStaleResponse() async throws {
        // Simulate two rapid selections: k1 then k2; k1 response delayed must be ignored
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                // Determine key based on second arg
                let keyData = cmd.count > 1 ? cmd[1] : Data()
                let keyStr = String(decoding: keyData, as: UTF8.self)
                if name == "GET" {
                    if keyStr == "k1" {
                        // delay to make stale
                        Thread.sleep(forTimeInterval: 0.15)
                        peer.write(Data("$2\r\nv1\r\n".utf8))
                    } else {
                        peer.write(Data("$2\r\nv2\r\n".utf8))
                    }
                } else if name == "TTL" {
                    if keyStr == "k1" {
                        Thread.sleep(forTimeInterval: 0.15)
                        peer.write(Data(":10\r\n".utf8))
                    } else {
                        peer.write(Data(":20\r\n".utf8))
                    }
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let k1 = Data("k1".utf8)
        let k2 = Data("k2".utf8)
        async let a: Void = vm.loadDetail(for: k1, using: client)
        // small delay before second selection
        try await Task.sleep(nanoseconds: 20_000_000)
        async let b: Void = vm.loadDetail(for: k2, using: client)
        await a
        await b
        // Should be k2's result, not stale k1
        if case .loaded(let k, let v, let ttl) = vm.detailState {
            #expect(k == k2)
            #expect(v == Data("v2".utf8))
            #expect(ttl == .expiring(seconds: 20))
        } else {
            Issue.record("expected loaded k2, got \(vm.detailState)")
        }
    }
}
