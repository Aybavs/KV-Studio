import Testing
import Foundation
@testable import KV_Studio

@Suite
struct BrowserDeletePreviewTests {
    @Test func emptyKeyPreview() {
        #expect(BrowserViewModel.deletePreview(for: Data()) == "(empty)")
    }
    @Test func utf8PreviewShort() {
        #expect(BrowserViewModel.deletePreview(for: Data("hello".utf8)) == "hello")
    }
    @Test func utf8PreviewExactLengthNotTruncated() {
        let s = String(repeating: "a", count: 64)
        #expect(BrowserViewModel.deletePreview(for: Data(s.utf8)).count == 64)
        #expect(BrowserViewModel.deletePreview(for: Data(s.utf8)) == s)
    }
    @Test func utf8PreviewTruncatesMiddleWithEllipsis() {
        let long = String(repeating: "a", count: 100)
        let preview = BrowserViewModel.deletePreview(for: Data(long.utf8))
        #expect(preview.count == 64)
        #expect(preview.contains("…"))
        #expect(preview.hasPrefix(String(repeating: "a", count: 31)))
        #expect(preview.hasSuffix(String(repeating: "a", count: 32)))
    }
    @Test func binaryPreviewUsesHex() {
        let key = Data([0xFF, 0x00, 0x01, 0x02])
        let preview = BrowserViewModel.deletePreview(for: key)
        #expect(preview == ValuePresentation.hexString(from: key))
    }
    @Test func binaryLongPreviewTruncates() {
        let key = Data(repeating: 0xFF, count: 100)
        let preview = BrowserViewModel.deletePreview(for: key)
        #expect(preview.count == 64)
        #expect(preview.contains("…"))
        // hex fallback is "ff ff ..." spaced, truncation still ellipsis
    }
    @Test func respectsCustomMaxLength() {
        let long = String(repeating: "b", count: 100)
        let preview = BrowserViewModel.deletePreview(for: Data(long.utf8), maxLength: 20)
        #expect(preview.count == 20)
        #expect(preview.contains("…"))
    }
}

@Suite
@MainActor
struct BrowserViewModelDeleteTests {
    private func makeClient(to server: FakeServer) async throws -> KVClient {
        let conn = KVConnection()
        try await conn.connect(to: ConnectionEndpoint(host: "127.0.0.1", port: server.port))
        return KVClient(connection: conn)
    }
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func deleteRemovesKeyAndClearsSelectionAndRefreshesDBSize() async throws {
        let key1 = bytes("k1")
        let key2 = bytes("k2")
        let key3 = bytes("k3")
        let delBox = LockedBox<[Data]?>(nil)
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "DEL" {
                    delBox.set(cmd)
                    peer.write(Data(":1\r\n".utf8))
                } else if name == "DBSIZE" {
                    peer.write(Data(":2\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [key1, key2, key3]), generation: g)
        vm.updateDBSize(3)
        vm.select(key2)
        let dg = vm.prepareDetailLoad(for: key2)
        vm.applyDetail(value: bytes("v2"), ttl: .persistent, key: key2, generation: dg)
        #expect(vm.selection == key2)
        #expect(vm.keys.count == 3)

        try await vm.deleteKey(key2, using: client)

        #expect(delBox.get() == [bytes("DEL"), key2])
        #expect(vm.keys == [key1, key3], "deleted key removed immediately")
        #expect(vm.selection == nil, "selection cleared when deleted key was selected")
        #expect(vm.detailState == .idle, "detail cleared when selected key deleted")
        #expect(vm.dbsize == 2, "DBSIZE refreshed after delete")
        #expect(vm.isDeleting == false, "isDeleting reset after operation")
    }

    @Test func deleteNonSelectedKeyKeepsSelection() async throws {
        let k1 = bytes("k1")
        let k2 = bytes("k2")
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "DEL" {
                    peer.write(Data(":1\r\n".utf8))
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
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [k1, k2]), generation: g)
        vm.select(k1)
        let dg = vm.prepareDetailLoad(for: k1)
        vm.applyDetail(value: bytes("v1"), ttl: .persistent, key: k1, generation: dg)

        try await vm.deleteKey(k2, using: client)

        #expect(vm.keys == [k1])
        #expect(vm.selection == k1)
        if case .loaded(let k, _, _) = vm.detailState {
            #expect(k == k1)
        } else {
            Issue.record("expected detail still loaded for k1")
        }
    }

    @Test func deleteBinaryKey() async throws {
        let key = Data([0x00, 0xFF, 0x01])
        let other = bytes("other")
        let delBox = LockedBox<[Data]?>(nil)
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "DEL" {
                    delBox.set(cmd)
                    peer.write(Data(":1\r\n".utf8))
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
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [key, other]), generation: g)
        vm.select(key)

        try await vm.deleteKey(key, using: client)

        #expect(delBox.get() == [bytes("DEL"), key], "binary key preserved in DEL")
        #expect(!vm.keys.contains(key))
        #expect(vm.selection == nil)
    }

    @Test func deleteFailureDoesNotMutateAndPropagates() async throws {
        let k1 = bytes("k1")
        let k2 = bytes("k2")
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "DEL" {
                    peer.write(Data("-ERR boom\r\n".utf8))
                } else if name == "DBSIZE" {
                    peer.write(Data(":2\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [k1, k2]), generation: g)
        vm.updateDBSize(2)
        vm.select(k1)
        let dg = vm.prepareDetailLoad(for: k1)
        vm.applyDetail(value: bytes("v1"), ttl: .persistent, key: k1, generation: dg)

        var didThrow = false
        do {
            try await vm.deleteKey(k1, using: client)
        } catch {
            didThrow = true
        }
        #expect(didThrow == true)
        #expect(vm.keys == [k1, k2], "keys unchanged on DEL failure")
        #expect(vm.selection == k1, "selection not cleared on failure")
        #expect(vm.dbsize == 2, "dbsize not refreshed on failure")
        #expect(vm.isDeleting == false)
        if case .loaded(let k, _, _) = vm.detailState {
            #expect(k == k1)
        } else {
            Issue.record("detail should remain loaded after failed delete")
        }
    }

    @Test func deleteWhenDELReturnsZeroStillRemovesLocally() async throws {
        let k1 = bytes("k1")
        let k2 = bytes("k2")
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "DEL" {
                    peer.write(Data(":0\r\n".utf8))
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
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [k1, k2]), generation: g)
        vm.select(k1)

        try await vm.deleteKey(k1, using: client)

        #expect(vm.keys == [k2])
        #expect(vm.selection == nil)
        #expect(vm.detailState == .idle)
        #expect(vm.dbsize == 1)
    }

    @Test func deleteRefreshDBSizeBestEffortOnFailureStillSucceeds() async throws {
        let k1 = bytes("k1")
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "DEL" {
                    peer.write(Data(":1\r\n".utf8))
                } else if name == "DBSIZE" {
                    peer.write(Data("-ERR fail\r\n".utf8))
                } else {
                    peer.write(Data("-ERR unknown\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [k1]), generation: g)
        vm.updateDBSize(5)
        vm.select(k1)

        try await vm.deleteKey(k1, using: client)

        #expect(vm.keys.isEmpty, "key removed even when DBSIZE fails")
        #expect(vm.selection == nil)
        #expect(vm.dbsize == 5, "dbsize unchanged on DBSIZE failure (best-effort)")
    }

    @Test func resetClearsDeletingFlag() async {
        let vm = BrowserViewModel()
        vm.reset()
        #expect(vm.isDeleting == false)
    }
}

// Simple thread-safe box
private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); let r = value; lock.unlock(); return r }
}
