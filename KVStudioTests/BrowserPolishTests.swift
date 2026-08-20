import Testing
import Foundation
@testable import KV_Studio

@Suite
@MainActor
struct BrowserEmptyStateTests {
    @Test func emptyDatabaseWhenNoKeysAndEmptySearchAndLoaded() {
        let vm = BrowserViewModel()
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: []), generation: g)
        #expect(vm.currentEmptyState == .emptyDatabase)
        #expect(vm.isShowingEmptyDatabase == true)
        #expect(vm.isShowingNoResults == false)
    }

    @Test func noResultsWhenNoKeysAndSearchAndLoaded() {
        let vm = BrowserViewModel()
        _ = vm.updateSearchText("hello")
        // updateSearchText puts into initialLoading; apply empty page
        let gen = vm.generation
        vm.apply(page: ScanPage(nextCursor: 0, keys: []), generation: gen)
        #expect(vm.currentEmptyState == .noSearchResults(pattern: "hello"))
        #expect(vm.isShowingNoResults == true)
        #expect(vm.isShowingEmptyDatabase == false)
    }

    @Test func noEmptyStateWhenKeysPresent() {
        let vm = BrowserViewModel()
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("k1".utf8)]), generation: g)
        #expect(vm.currentEmptyState == nil)
        #expect(vm.isShowingEmptyDatabase == false)
        #expect(vm.isShowingNoResults == false)
    }

    @Test func noEmptyStateWhileLoading() {
        let vm = BrowserViewModel()
        _ = vm.prepareInitialLoad()
        // state is initialLoading, keys empty -> not yet loaded
        #expect(vm.currentEmptyState == nil)
    }

    @Test func emptyStateDifferentiatedIdentifiers() {
        let vm = BrowserViewModel()
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: []), generation: g)
        #expect(vm.emptyStateTitle == "Database is empty.")
        // now search
        _ = vm.updateSearchText("xyz")
        let gen2 = vm.generation
        vm.apply(page: ScanPage(nextCursor: 0, keys: []), generation: gen2)
        #expect(vm.emptyStateTitle == "No results for current search.")
        #expect(vm.emptyStateTitleForNoResults?.contains("xyz") == true || vm.emptyStateTitle == "No results for current search.")
    }
}

@Suite
@MainActor
struct BrowserLoadingStateTests {
    @Test func initialLoadingShowsSkeletonWhenKeysEmpty() {
        let vm = BrowserViewModel()
        _ = vm.prepareInitialLoad()
        #expect(vm.isShowingInitialSkeleton == true)
        #expect(vm.isShowingRefreshOverlay == false)
    }

    @Test func refreshingShowsSkeletonWhenKeysEmpty() {
        let vm = BrowserViewModel()
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: []), generation: g)
        _ = vm.prepareRefresh()
        #expect(vm.isShowingInitialSkeleton == true)
    }

    @Test func refreshingShowsOverlayWhenKeysPresent() {
        let vm = BrowserViewModel()
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("k1".utf8)]), generation: g)
        _ = vm.prepareRefresh()
        #expect(vm.isShowingRefreshOverlay == true)
        #expect(vm.isShowingInitialSkeleton == false)
    }

    @Test func loadedDoesNotShowSkeletonOrOverlay() {
        let vm = BrowserViewModel()
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("k1".utf8)]), generation: g)
        #expect(vm.isShowingInitialSkeleton == false)
        #expect(vm.isShowingRefreshOverlay == false)
    }

    @Test func loadingMoreDoesNotShowSkeleton() {
        let vm = BrowserViewModel()
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 10, keys: [Data("k1".utf8)]), generation: g)
        _ = vm.prepareLoadMore()
        #expect(vm.isShowingInitialSkeleton == false)
        #expect(vm.isShowingRefreshOverlay == false)
        #expect(vm.state == .loadingMore)
    }
}

@Suite
@MainActor
struct BrowserShortcutEligibilityTests {
    @Test func canRefreshWhenConnectedState() {
        let vm = BrowserViewModel()
        let g = vm.prepareInitialLoad()
        vm.apply(page: ScanPage(nextCursor: 0, keys: [Data("k1".utf8)]), generation: g)
        #expect(vm.canRefresh == true)
        _ = vm.prepareInitialLoad()
        #expect(vm.canRefresh == false)
        _ = vm.prepareRefresh()
        #expect(vm.canRefresh == false)
    }

    @Test func canSaveWhenLoadedDetail() {
        let vm = BrowserViewModel()
        let key = Data("k".utf8)
        #expect(vm.canSave == false)
        let g = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: Data("v".utf8), ttl: .persistent, key: key, generation: g)
        #expect(vm.canSave == true)
        #expect(vm.canDelete == true)
    }

    @Test func canDeleteOnlyWhenDetailLoaded() {
        let vm = BrowserViewModel()
        #expect(vm.canDelete == false)
        let key = Data("k".utf8)
        let g = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: Data("v".utf8), ttl: .persistent, key: key, generation: g)
        #expect(vm.canDelete == true)
        let g2 = vm.prepareDetailLoad(for: key)
        vm.applyDetail(value: nil, ttl: .missing, key: key, generation: g2)
        #expect(vm.canDelete == false)
    }
}
