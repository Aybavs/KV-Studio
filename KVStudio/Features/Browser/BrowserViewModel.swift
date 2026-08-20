import Foundation
import Observation

enum BrowserState: Equatable, Sendable {
    case idle
    case initialLoading
    case loaded
    case loadingMore
    case refreshing
    case failed
}

@MainActor
@Observable
final class BrowserViewModel {
    static let scanCount = 500
    static let prefetchThreshold = 30

    private(set) var keys: [Data] = []
    private(set) var cursor: UInt64 = 0
    private(set) var generation: UInt64 = 0
    private(set) var endReached: Bool = false
    var selection: Data?
    var searchText: String = ""
    private(set) var dbsize: Int = 0
    private(set) var state: BrowserState = .idle
    private(set) var errorMessage: String?

    var nextCursor: UInt64 { cursor }

    func matchPattern() -> Data? {
        Self.matchPattern(for: searchText)
    }

    static func matchPattern(for text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("*") || trimmed.contains("?") || trimmed.contains("[") {
            return Data(trimmed.utf8)
        }
        var escaped = ""
        escaped.reserveCapacity(trimmed.count + 2)
        for ch in trimmed {
            if ch == "*" || ch == "?" || ch == "[" || ch == "]" || ch == "\\" {
                escaped.append("\\")
            }
            escaped.append(ch)
        }
        return Data("*\(escaped)*".utf8)
    }

    func shouldLoadMore(at index: Int) -> Bool {
        guard state == .loaded, !endReached, cursor != 0 else { return false }
        guard !keys.isEmpty else { return false }
        return index >= max(0, keys.count - Self.prefetchThreshold)
    }

    @discardableResult
    func prepareInitialLoad() -> UInt64 {
        generation &+= 1
        cursor = 0
        endReached = false
        keys = []
        state = .initialLoading
        errorMessage = nil
        return generation
    }

    func prepareLoadMore() -> UInt64? {
        guard state == .loaded, !endReached, cursor != 0 else { return nil }
        state = .loadingMore
        errorMessage = nil
        return generation
    }

    @discardableResult
    func prepareRefresh() -> UInt64 {
        generation &+= 1
        cursor = 0
        endReached = false
        state = .refreshing
        errorMessage = nil
        return generation
    }

    @discardableResult
    func updateSearchText(_ text: String) -> UInt64? {
        guard text != searchText else { return nil }
        searchText = text
        generation &+= 1
        cursor = 0
        endReached = false
        keys = []
        selection = nil
        state = .initialLoading
        errorMessage = nil
        return generation
    }

    func apply(page: ScanPage, generation: UInt64) {
        guard generation == self.generation else { return }
        if state == .loadingMore {
            var seen = Set(keys)
            var unique: [Data] = []
            unique.reserveCapacity(page.keys.count)
            for k in page.keys where seen.insert(k).inserted {
                unique.append(k)
            }
            keys.append(contentsOf: unique)
        } else {
            var seen = Set<Data>()
            var unique: [Data] = []
            unique.reserveCapacity(page.keys.count)
            for k in page.keys where seen.insert(k).inserted {
                unique.append(k)
            }
            keys = unique
        }
        cursor = page.nextCursor
        endReached = page.nextCursor == 0
        state = .loaded
        errorMessage = nil
        if let sel = selection, !keys.contains(sel) {
            selection = nil
        }
    }

    func applyFailure(_ error: Error, generation: UInt64) {
        guard generation == self.generation else { return }
        if let kv = error as? KVClientError, case .serverError(let data) = kv {
            errorMessage = String(decoding: data, as: UTF8.self)
        } else {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        state = .failed
    }

    func updateDBSize(_ size: Int) {
        dbsize = size
    }

    func isInvalidCursorError(_ error: Error) -> Bool {
        guard let kv = error as? KVClientError else { return false }
        if case .serverError(let data) = kv {
            let msg = String(decoding: data, as: UTF8.self).lowercased()
            return msg.contains("invalid cursor")
        }
        return false
    }

    func isSessionLimitError(_ error: Error) -> Bool {
        guard let kv = error as? KVClientError else { return false }
        if case .serverError(let data) = kv {
            let msg = String(decoding: data, as: UTF8.self).lowercased()
            return msg.contains("scan session limit reached")
        }
        return false
    }

    var isRecoverableScanError: Bool {
        guard state == .failed, let msg = errorMessage?.lowercased() else { return false }
        return msg.contains("invalid cursor") || msg.contains("scan session limit reached")
    }

    @discardableResult
    func restartAfterRecoverableFailure() -> UInt64? {
        guard state == .failed, isRecoverableScanError else { return nil }
        generation &+= 1
        cursor = 0
        endReached = false
        state = .refreshing
        errorMessage = nil
        return generation
    }

    func select(_ key: Data?) {
        selection = key
    }

    func reset() {
        keys = []
        cursor = 0
        endReached = false
        generation = 0
        selection = nil
        searchText = ""
        dbsize = 0
        state = .idle
        errorMessage = nil
    }

    func loadInitial(using client: KVClient, count: Int = scanCount) async {
        let gen = prepareInitialLoad()
        await performScan(cursor: 0, generation: gen, client: client, count: count, isRetry: false)
        await refreshDBSize(using: client)
    }

    func loadMore(using client: KVClient, count: Int = scanCount) async {
        guard let gen = prepareLoadMore() else { return }
        let cur = cursor
        let pattern = matchPattern()
        do {
            let page = try await client.scan(cursor: cur, match: pattern, count: count)
            apply(page: page, generation: gen)
        } catch {
            if isInvalidCursorError(error) || isSessionLimitError(error) {
                let retryGen = restartAfterRecoverableFailure() ?? gen
                await performScan(cursor: 0, generation: retryGen, client: client, count: count, isRetry: true)
                return
            }
            applyFailure(error, generation: gen)
        }
    }

    func refresh(using client: KVClient, count: Int = scanCount) async {
        let gen = prepareRefresh()
        await performScan(cursor: 0, generation: gen, client: client, count: count, isRetry: false)
        await refreshDBSize(using: client)
    }

    func applySearch(_ text: String, using client: KVClient, count: Int = scanCount) async {
        guard let gen = updateSearchText(text) else { return }
        await performScan(cursor: 0, generation: gen, client: client, count: count, isRetry: false)
        await refreshDBSize(using: client)
    }

    private func performScan(cursor: UInt64, generation: UInt64, client: KVClient, count: Int, isRetry: Bool) async {
        let pattern = matchPattern()
        do {
            let page = try await client.scan(cursor: cursor, match: pattern, count: count)
            guard generation == self.generation else { return }
            apply(page: page, generation: generation)
        } catch {
            guard generation == self.generation else { return }
            if !isRetry && (isInvalidCursorError(error) || isSessionLimitError(error)) {
                let retryGen = restartAfterRecoverableFailure() ?? generation
                await performScan(cursor: 0, generation: retryGen, client: client, count: count, isRetry: true)
                return
            }
            applyFailure(error, generation: generation)
        }
    }

    private func refreshDBSize(using client: KVClient) async {
        let gen = generation
        do {
            let size = try await client.dbSize()
            guard gen == generation else { return }
            dbsize = size
        } catch {
            return
        }
    }
}
