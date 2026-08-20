import Testing
@testable import KV_Studio

@Suite
struct LogStoreTests {

    @Test func keepsAppendedLinesInOrder() {
        let store = LogStore(maxLines: 10, maxBytes: 1_000)
        store.append("first")
        store.append("second")
        #expect(store.snapshot.map(\.text) == ["first", "second"])
    }

    @Test func evictsOldestWhenLineCapIsExceeded() {
        let store = LogStore(maxLines: 3, maxBytes: 1_000_000)
        for line in ["a", "b", "c", "d", "e"] { store.append(line) }
        #expect(store.snapshot.map(\.text) == ["c", "d", "e"])
    }

    @Test func evictsOldestWhenByteCapIsExceeded() {
        let store = LogStore(maxLines: 1_000, maxBytes: 10)
        store.append("12345")
        store.append("67890")
        store.append("abcde")
        #expect(store.snapshot.map(\.text) == ["67890", "abcde"])
    }

    // "dünya" is 5 characters but 6 UTF-8 bytes, so a character-counting cap would keep both.
    @Test func measuresBytesNotCharacters() {
        let store = LogStore(maxLines: 1_000, maxBytes: 7)
        store.append("dünya")
        #expect(store.snapshot.count == 1)
        store.append("ok")
        #expect(store.snapshot.map(\.text) == ["ok"])
    }

    @Test func keepsALineLongerThanTheByteCapRatherThanLoopingForever() {
        let store = LogStore(maxLines: 1_000, maxBytes: 4)
        store.append(String(repeating: "x", count: 64))
        #expect(store.snapshot.count == 1)
    }

    @Test func identifiersAreUniqueAcrossEviction() {
        let store = LogStore(maxLines: 2, maxBytes: 1_000_000)
        for line in ["a", "b", "c", "d"] { store.append(line) }
        let ids = store.snapshot.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func clearEmptiesTheBuffer() {
        let store = LogStore(maxLines: 10, maxBytes: 1_000)
        store.append("noise")
        store.clear()
        #expect(store.snapshot.isEmpty)
    }

    @Test func clearResetsTheByteBudget() {
        let store = LogStore(maxLines: 100, maxBytes: 10)
        store.append("1234567890")
        store.clear()
        store.append("abc")
        #expect(store.snapshot.map(\.text) == ["abc"])
    }

    @Test func filteringIsCaseInsensitiveSubstringMatching() {
        let store = LogStore(maxLines: 100, maxBytes: 10_000)
        store.append("level=INFO msg=listening")
        store.append("level=ERROR msg=boom")
        #expect(store.filtered(by: "error").map(\.text) == ["level=ERROR msg=boom"])
    }

    @Test func blankFilterReturnsEverything() {
        let store = LogStore(maxLines: 100, maxBytes: 10_000)
        store.append("one")
        store.append("two")
        #expect(store.filtered(by: "   ").count == 2)
    }

    @Test func concurrentAppendsKeepTheBufferConsistent() async {
        let store = LogStore(maxLines: 500, maxBytes: 1_000_000)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask { store.append("line-\(index)") }
            }
        }
        #expect(store.snapshot.count == 100)
        #expect(Set(store.snapshot.map(\.id)).count == 100)
    }

    @Test func concurrentAppendsRespectTheLineCap() async {
        let store = LogStore(maxLines: 20, maxBytes: 1_000_000)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask { store.append("line-\(index)") }
            }
        }
        #expect(store.snapshot.count == 20)
    }
}

@MainActor
@Suite
struct LogsViewModelTests {

    @Test func showsEverythingWhenUnfiltered() {
        let model = LogsViewModel(store: LogStore(maxLines: 100, maxBytes: 10_000))
        model.append("alpha")
        model.append("beta")
        #expect(model.visibleEntries.map(\.text) == ["alpha", "beta"])
    }

    @Test func filterNarrowsVisibleEntriesWithoutDroppingStoredOnes() {
        let store = LogStore(maxLines: 100, maxBytes: 10_000)
        let model = LogsViewModel(store: store)
        model.append("level=INFO msg=listening")
        model.append("level=ERROR msg=boom")
        model.filter = "error"
        #expect(model.visibleEntries.count == 1)
        #expect(store.snapshot.count == 2)
    }

    @Test func clearingTheFilterRestoresEverything() {
        let model = LogsViewModel(store: LogStore(maxLines: 100, maxBytes: 10_000))
        model.append("alpha")
        model.append("beta")
        model.filter = "alpha"
        model.filter = ""
        #expect(model.visibleEntries.count == 2)
    }

    @Test func clearEmptiesTheVisibleBufferAndTheStore() {
        let store = LogStore(maxLines: 100, maxBytes: 10_000)
        let model = LogsViewModel(store: store)
        model.append("alpha")
        model.clear()
        #expect(model.visibleEntries.isEmpty)
        #expect(store.snapshot.isEmpty)
    }

    @Test func ingestingAStreamAppendsEveryLine() async {
        let model = LogsViewModel(store: LogStore(maxLines: 100, maxBytes: 10_000))
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.yield("one")
        continuation.yield("two")
        continuation.finish()
        await model.ingest(stream)
        #expect(model.visibleEntries.map(\.text) == ["one", "two"])
    }

    @Test func ingestionKeepsTheActiveFilterApplied() async {
        let model = LogsViewModel(store: LogStore(maxLines: 100, maxBytes: 10_000))
        model.filter = "keep"
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.yield("drop this")
        continuation.yield("keep this")
        continuation.finish()
        await model.ingest(stream)
        #expect(model.visibleEntries.map(\.text) == ["keep this"])
    }
}
