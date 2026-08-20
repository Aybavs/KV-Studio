import Testing
import Foundation
@testable import KV_Studio

@Suite
@MainActor
struct BrowserInfiniteScrollConstantsTests {
    @Test func scanCountIs500() {
        #expect(BrowserViewModel.scanCount == 500)
    }

    @Test func prefetchThresholdIs30() {
        #expect(BrowserViewModel.prefetchThreshold == 30)
    }
}

@Suite
@MainActor
struct BrowserDeduplicationTests {
    @Test func applyDedupesDuplicateKeysWithinSinglePage() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 1, keys: [Data("a".utf8), Data("a".utf8), Data("b".utf8)]), generation: gen)
        #expect(vm.keys == [Data("a".utf8), Data("b".utf8)])
    }

    @Test func loadMoreDedupesAlreadySeenKeys() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 10, keys: [Data("k1".utf8)]), generation: gen)
        _ = vm.prepareLoadMore()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("k1".utf8), Data("k2".utf8), Data("k2".utf8)]), generation: gen)
        #expect(vm.keys == [Data("k1".utf8), Data("k2".utf8)])
    }

    @Test func loadMoreDedupesDoesNotAffectNewGenerationAfterRefresh() {
        let vm = BrowserViewModel()
        let g1 = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 5, keys: [Data("k1".utf8)]), generation: g1)
        let g2 = vm.prepareRefresh()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("k1".utf8), Data("k2".utf8)]), generation: g2)
        #expect(vm.keys == [Data("k1".utf8), Data("k2".utf8)])
    }
}

@Suite
@MainActor
struct BrowserPrefetchTests {
    @Test func shouldLoadMoreNearEndWhenLoadedAndHasCursor() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        let keys = (0..<100).map { Data("k\($0)".utf8) }
        vm.apply(page: ScanPage(nextCursor: 99, keys: keys), generation: gen)
        #expect(vm.shouldLoadMore(at: 70) == true)
        #expect(vm.shouldLoadMore(at: 69) == false)
        #expect(vm.shouldLoadMore(at: 99) == true)
    }

    @Test func shouldNotLoadMoreWhenNotNearEnd() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        let keys = (0..<100).map { Data("k\($0)".utf8) }
        vm.apply(page: ScanPage(nextCursor: 99, keys: keys), generation: gen)
        #expect(vm.shouldLoadMore(at: 10) == false)
    }

    @Test func shouldNotLoadMoreWhenEndReachedOrIdle() {
        let vm = BrowserViewModel()
        #expect(vm.shouldLoadMore(at: 0) == false)
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("a".utf8)]), generation: gen)
        #expect(vm.endReached == true)
        #expect(vm.shouldLoadMore(at: 0) == false)
    }

    @Test func shouldNotLoadMoreWhileLoadingMore() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 10, keys: [Data("a".utf8)]), generation: gen)
        _ = vm.prepareLoadMore()
        #expect(vm.state == .loadingMore)
        #expect(vm.shouldLoadMore(at: 0) == false)
    }
}

@Suite
@MainActor
struct BrowserSingleFlightTests {
    @Test func singleInflightPerGeneration() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 10, keys: [Data("a".utf8)]), generation: gen)
        let first = vm.prepareLoadMore()
        #expect(first == gen)
        let second = vm.prepareLoadMore()
        #expect(second == nil)
    }

    @Test func stopsAtCursorZero() {
        let vm = BrowserViewModel()
        let gen = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("a".utf8)]), generation: gen)
        #expect(vm.endReached == true)
        #expect(vm.prepareLoadMore() == nil)
    }
}
