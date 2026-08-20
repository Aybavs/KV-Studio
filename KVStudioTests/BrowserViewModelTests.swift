import Testing
import Foundation
@testable import KV_Studio

@Suite
@MainActor
struct BrowserViewModelInitialStateTests {
    @Test func startsIdleWithEmptyState() {
        let vm = BrowserViewModel()
        #expect(vm.state == .idle)
        #expect(vm.keys.isEmpty)
        #expect(vm.cursor == 0)
        #expect(vm.generation == 0)
        #expect(vm.endReached == false)
        #expect(vm.dbsize == 0)
        #expect(vm.selection == nil)
        #expect(vm.searchText == "")
        #expect(vm.errorMessage == nil)
        #expect(vm.nextCursor == 0)
    }
}

@Suite
@MainActor
struct BrowserViewModelTransitionsTests {
    @Test func prepareInitialLoadMovesToInitialLoadingAndIncrementsGeneration() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        #expect(gen == 1)
        #expect(vm.generation == 1)
        #expect(vm.state == .initialLoading)
        #expect(vm.cursor == 0)
        #expect(vm.endReached == false)
        #expect(vm.keys.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test func prepareInitialLoadClearsPreviousKeys() {
        let vm = BrowserViewModel()
        let g1 = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 42, keys: [Data("a".utf8)]), generation: g1)
        #expect(vm.keys.count == 1)
        let g2 = vm.prepareInitialLoad()
        #expect(vm.keys.isEmpty)
        #expect(vm.cursor == 0)
        #expect(g2 == 2)
    }

    @Test func applyWithMatchingGenerationUpdatesKeysCursorAndState() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 99, keys: [Data("k1".utf8), Data("k2".utf8)]), generation: gen)
        #expect(vm.state == .loaded)
        #expect(vm.keys == [Data("k1".utf8), Data("k2".utf8)])
        #expect(vm.cursor == 99)
        #expect(vm.endReached == false)
        #expect(vm.nextCursor == 99)
    }

    @Test func applyWithZeroCursorMarksEndReached() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("k1".utf8)]), generation: gen)
        #expect(vm.state == .loaded)
        #expect(vm.cursor == 0)
        #expect(vm.endReached == true)
    }

    @Test func emptyPageWithZeroCursorMarksEndReached() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: []), generation: gen)
        #expect(vm.keys.isEmpty)
        #expect(vm.endReached == true)
        #expect(vm.state == .loaded)
    }

    @Test func staleGenerationIsIgnored() {
        let vm = BrowserViewModel()
        let g1 = vm.prepareInitialLoad()
        let g2 = vm.prepareInitialLoad()
        #expect(g1 == 1)
        #expect(g2 == 2)
        vm.apply(page: ScanPage(nextCursor: 42, keys: [Data("stale".utf8)]), generation: g1)
        #expect(vm.keys.isEmpty, "stale page must not mutate state")
        #expect(vm.state == .initialLoading)
        vm.apply(page: ScanPage(nextCursor: 7, keys: [Data("fresh".utf8)]), generation: g2)
        #expect(vm.keys == [Data("fresh".utf8)])
        #expect(vm.cursor == 7)
        #expect(vm.state == .loaded)
    }

    @Test func staleFailureIsIgnored() {
        let vm = BrowserViewModel()
        let g1 = vm.prepareInitialLoad()
        let g2 = vm.prepareInitialLoad()
        vm.applyFailure(KVClientError.serverError(Data("ERR invalid cursor".utf8)), generation: g1)
        #expect(vm.state == .initialLoading, "stale failure must be ignored")
        vm.applyFailure(KVClientError.serverError(Data("ERR boom".utf8)), generation: g2)
        #expect(vm.state == .failed)
    }

    @Test func prepareLoadMoreOnlyWhenLoadedAndNotEndReached() {
        let vm = BrowserViewModel()
        #expect(vm.prepareLoadMore() == nil)
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 10, keys: [Data("a".utf8)]), generation: gen)
        #expect(vm.state == .loaded)
        let moreGen = vm.prepareLoadMore()
        #expect(moreGen == gen)
        #expect(vm.state == .loadingMore)
        #expect(vm.prepareLoadMore() == nil, "second loadMore while loadingMore must be nil")
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("b".utf8)]), generation: gen)
        #expect(vm.state == .loaded)
        #expect(vm.keys == [Data("a".utf8), Data("b".utf8)])
        #expect(vm.endReached == true)
        #expect(vm.prepareLoadMore() == nil, "loadMore when endReached must be nil")
    }

    @Test func loadMoreAppendsRatherThanReplaces() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 5, keys: [Data("k1".utf8)]), generation: gen)
        _ = vm.prepareLoadMore()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("k2".utf8), Data("k3".utf8)]), generation: gen)
        #expect(vm.keys == [Data("k1".utf8), Data("k2".utf8), Data("k3".utf8)])
    }

    @Test func prepareRefreshIncrementsGenerationAndPreservesKeysUntilApply() {
        let vm = BrowserViewModel()
        let g1 = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("old".utf8)]), generation: g1)
        let g2 = vm.prepareRefresh()
        #expect(g2 == g1 + 1)
        #expect(vm.state == .refreshing)
        #expect(vm.cursor == 0)
        #expect(vm.endReached == false)
        #expect(vm.keys == [Data("old".utf8)], "refresh preserves keys until new page arrives")
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("new".utf8)]), generation: g2)
        #expect(vm.keys == [Data("new".utf8)])
        #expect(vm.state == .loaded)
    }

    @Test func updateSearchTextResetsAndIncrementsGeneration() {
        let vm = BrowserViewModel()
        let g1 = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 9, keys: [Data("a".utf8)]), generation: g1)
        let g2 = vm.updateSearchText("user:*")
        #expect(g2 == 2)
        #expect(vm.searchText == "user:*")
        #expect(vm.generation == 2)
        #expect(vm.keys.isEmpty)
        #expect(vm.cursor == 0)
        #expect(vm.state == .initialLoading)
        #expect(vm.selection == nil)
        #expect(vm.updateSearchText("user:*") == nil, "same text must not bump generation")
    }

    @Test func failedStatePreservesKeysAndStoresMessage() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 5, keys: [Data("k1".utf8)]), generation: gen)
        _ = vm.prepareLoadMore()
        vm.applyFailure(KVClientError.serverError(Data("ERR boom".utf8)), generation: gen)
        #expect(vm.state == .failed)
        #expect(vm.keys == [Data("k1".utf8)], "failed paging must keep already loaded keys")
        #expect(vm.errorMessage != nil)
    }

    @Test func selectionClearedWhenSelectedKeyDisappears() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.select(Data("keep".utf8))
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("other".utf8)]), generation: gen)
        #expect(vm.selection == nil)
    }

    @Test func selectionPersistsWhenStillPresent() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("k1".utf8), Data("k2".utf8)]), generation: gen)
        vm.select(Data("k1".utf8))
        let g2 = vm.prepareRefresh()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("k1".utf8), Data("k3".utf8)]), generation: g2)
        #expect(vm.selection == Data("k1".utf8))
    }

    @Test func updateDBSizeSetsValue() {
        let vm = BrowserViewModel()
        vm.updateDBSize(42)
        #expect(vm.dbsize == 42)
        vm.updateDBSize(0)
        #expect(vm.dbsize == 0)
    }

    @Test func resetReturnsToIdle() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 5, keys: [Data("k".utf8)]), generation: gen)
        vm.updateDBSize(10)
        vm.select(Data("k".utf8))
        vm.reset()
        #expect(vm.state == .idle)
        #expect(vm.keys.isEmpty)
        #expect(vm.cursor == 0)
        #expect(vm.generation == 0)
        #expect(vm.selection == nil)
        #expect(vm.searchText == "")
        #expect(vm.dbsize == 0)
    }
}

@Suite
@MainActor
struct BrowserMatchPatternTests {
    @Test func emptyTextProducesNoMatch() {
        #expect(BrowserViewModel.matchPattern(for: "") == nil)
        #expect(BrowserViewModel.matchPattern(for: "   ") == nil)
    }

    @Test func explicitGlobIsPassedThrough() {
        #expect(BrowserViewModel.matchPattern(for: "user:*") == Data("user:*".utf8))
        #expect(BrowserViewModel.matchPattern(for: "a?b") == Data("a?b".utf8))
        #expect(BrowserViewModel.matchPattern(for: "a[bc]") == Data("a[bc]".utf8))
    }

    @Test func plainTextIsWrappedWithStars() {
        #expect(BrowserViewModel.matchPattern(for: "hello") == Data("*hello*".utf8))
        #expect(BrowserViewModel.matchPattern(for: "foo") == Data("*foo*".utf8))
    }

    @Test func plainTextEscapesGlobMetacharsBeforeWrapping() {
        #expect(BrowserViewModel.matchPattern(for: "a*b") == Data("a*b".utf8), "contains * so treated as explicit glob")
        let pattern = BrowserViewModel.matchPattern(for: "a\\b")
        #expect(pattern == Data("*a\\\\b*".utf8))
    }
}

@Suite
@MainActor
struct BrowserRecoverableScanErrorTests {
    @Test func detectsInvalidCursor() {
        let vm = BrowserViewModel()
        let err = KVClientError.serverError(Data("ERR invalid cursor".utf8))
        #expect(vm.isInvalidCursorError(err) == true)
        #expect(vm.isSessionLimitError(err) == false)
        #expect(vm.isInvalidCursorError(KVClientError.serverError(Data("ERR Invalid Cursor '123'".utf8))) == true)
    }

    @Test func detectsSessionLimit() {
        let vm = BrowserViewModel()
        let err = KVClientError.serverError(Data("ERR scan session limit reached".utf8))
        #expect(vm.isSessionLimitError(err) == true)
        #expect(vm.isInvalidCursorError(err) == false)
    }

    @Test func nonRecoverableErrorsReturnFalse() {
        let vm = BrowserViewModel()
        #expect(vm.isInvalidCursorError(KVClientError.serverError(Data("ERR wrong number of arguments".utf8))) == false)
        #expect(vm.isSessionLimitError(KVClientError.serverError(Data("ERR syntax error".utf8))) == false)
        #expect(vm.isInvalidCursorError(ConnectionError.notConnected) == false)
    }

    @Test func failedWithInvalidCursorIsRecoverable() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.applyFailure(KVClientError.serverError(Data("ERR invalid cursor".utf8)), generation: gen)
        #expect(vm.state == .failed)
        #expect(vm.isRecoverableScanError == true)
        let retry = vm.restartAfterRecoverableFailure()
        #expect(retry != nil)
        #expect(vm.state == .refreshing)
        #expect(vm.cursor == 0)
        #expect(vm.generation == gen + 1)
    }

    @Test func failedWithSessionLimitIsRecoverable() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.applyFailure(KVClientError.serverError(Data("ERR scan session limit reached (16)".utf8)), generation: gen)
        #expect(vm.isRecoverableScanError == true)
        #expect(vm.restartAfterRecoverableFailure() != nil)
    }

    @Test func nonRecoverableFailureDoesNotRestart() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.applyFailure(KVClientError.serverError(Data("ERR boom".utf8)), generation: gen)
        #expect(vm.isRecoverableScanError == false)
        #expect(vm.restartAfterRecoverableFailure() == nil)
        #expect(vm.state == .failed)
    }

    @Test func staleRestartIsIgnored() {
        let vm = BrowserViewModel()
        let g1 = vm.prepareInitialLoad()
        vm.applyFailure(KVClientError.serverError(Data("ERR invalid cursor".utf8)), generation: g1)
        let retry = vm.restartAfterRecoverableFailure()
        #expect(retry == 2)
        let staleGen = g1
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("stale".utf8)]), generation: staleGen)
        #expect(vm.keys.isEmpty)
        #expect(vm.state == .refreshing)
    }
}

private func browserScanReply(cursor: String, keys: [String]) -> String {
    var body = "*2\r\n$\(cursor.utf8.count)\r\n\(cursor)\r\n*\(keys.count)\r\n"
    for k in keys { body += "$\(k.utf8.count)\r\n\(k)\r\n" }
    return body
}

private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        count += 1
        let c = count
        lock.unlock()
        return c
    }
}

@Suite
@MainActor
struct BrowserAsyncTraversalTests {
    private func makeClient(to server: FakeServer) async throws -> KVClient {
        let conn = KVConnection()
        try await conn.connect(to: ConnectionEndpoint(host: "127.0.0.1", port: server.port))
        return KVClient(connection: conn)
    }

    @Test func loadInitialPopulatesKeysAndDBSizeAndEndReached() async throws {
        let server = try FakeServer(maxPeers: 8) { peer in
            guard let cmd = peer.readCommand() else { return }
            let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
            if name == "SCAN" {
                peer.write(Data(browserScanReply(cursor: "0", keys: ["k1", "k2"]).utf8))
            } else if name == "DBSIZE" {
                peer.write(Data(":2\r\n".utf8))
            } else {
                peer.write(Data("+PONG\r\n".utf8))
            }
            guard let cmd2 = peer.readCommand() else { return }
            let name2 = String(decoding: cmd2.first ?? Data(), as: UTF8.self).uppercased()
            if name2 == "SCAN" {
                peer.write(Data(browserScanReply(cursor: "0", keys: ["k1", "k2"]).utf8))
            } else if name2 == "DBSIZE" {
                peer.write(Data(":2\r\n".utf8))
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        await vm.loadInitial(using: client, count: 500)
        #expect(vm.state == .loaded)
        #expect(vm.keys == [Data("k1".utf8), Data("k2".utf8)])
        #expect(vm.cursor == 0)
        #expect(vm.endReached == true)
    }

    @Test func loadMoreAppendsWhenCursorAdvanced() async throws {
        let counter = ScanCounter()
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "SCAN" {
                    let n = counter.next()
                    if n == 1 {
                        peer.write(Data(browserScanReply(cursor: "10", keys: ["k1"]).utf8))
                    } else if n == 2 {
                        let c = cmd[1]
                        #expect(c == Data("10".utf8))
                        peer.write(Data(browserScanReply(cursor: "0", keys: ["k2"]).utf8))
                    } else {
                        peer.write(Data(browserScanReply(cursor: "0", keys: []).utf8))
                    }
                } else if name == "DBSIZE" {
                    peer.write(Data(":2\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        await vm.loadInitial(using: client, count: 1)
        #expect(vm.keys == [Data("k1".utf8)])
        #expect(vm.cursor == 10)
        await vm.loadMore(using: client, count: 1)
        #expect(vm.keys == [Data("k1".utf8), Data("k2".utf8)])
        #expect(vm.cursor == 0)
        #expect(vm.endReached == true)
    }

    @Test func invalidCursorDuringLoadMoreRetriesFromZero() async throws {
        let counter = ScanCounter()
        let server = try FakeServer(maxPeers: 8) { peer in
            while let cmd = peer.readCommand() {
                let name = String(decoding: cmd.first ?? Data(), as: UTF8.self).uppercased()
                if name == "SCAN" {
                    let n = counter.next()
                    if n == 1 {
                        peer.write(Data(browserScanReply(cursor: "77", keys: ["k1"]).utf8))
                    } else if n == 2 {
                        peer.write(Data("-ERR invalid cursor\r\n".utf8))
                    } else if n == 3 {
                        let cur = cmd[1]
                        #expect(cur == Data("0".utf8))
                        peer.write(Data(browserScanReply(cursor: "0", keys: ["k1", "k2"]).utf8))
                    }
                } else if name == "DBSIZE" {
                    peer.write(Data(":1\r\n".utf8))
                }
            }
        }
        defer { server.stop() }
        let client = try await makeClient(to: server)
        let vm = BrowserViewModel()
        await vm.loadInitial(using: client, count: 500)
        #expect(vm.keys == [Data("k1".utf8)])
        #expect(vm.cursor == 77)
        await vm.loadMore(using: client, count: 500)
        #expect(vm.state == .loaded)
        #expect(vm.keys.contains(Data("k1".utf8)))
    }
}
