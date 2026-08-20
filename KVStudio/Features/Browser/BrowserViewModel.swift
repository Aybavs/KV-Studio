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

enum BrowserEmptyState: Equatable, Sendable {
    case emptyDatabase
    case noSearchResults(pattern: String)
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
    private(set) var detailState: BrowserDetailState = .idle
    private(set) var detailGeneration: UInt64 = 0
    var preserveTTL: Bool = false
    private(set) var isSaving: Bool = false
    private(set) var isDeleting: Bool = false

    var nextCursor: UInt64 { cursor }

    // MARK: - Polish helpers (Task 25)

    var currentEmptyState: BrowserEmptyState? {
        guard keys.isEmpty, state == .loaded else { return nil }
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyDatabase
        } else {
            return .noSearchResults(pattern: searchText)
        }
    }

    var isShowingEmptyDatabase: Bool { currentEmptyState == .emptyDatabase }
    var isShowingNoResults: Bool {
        if case .noSearchResults = currentEmptyState { return true }
        return false
    }

    var emptyStateTitle: String {
        switch currentEmptyState {
        case .emptyDatabase: return "Database is empty."
        case .noSearchResults: return "No results for current search."
        case nil:
            if keys.isEmpty && state == .loaded && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Database is empty."
            }
            return "No results for current search."
        }
    }

    var emptyStateTitleForNoResults: String? {
        if case .noSearchResults(let pattern) = currentEmptyState { return pattern }
        return nil
    }

    var isShowingInitialSkeleton: Bool {
        keys.isEmpty && (state == .initialLoading || state == .refreshing)
    }

    var isShowingRefreshOverlay: Bool {
        !keys.isEmpty && state == .refreshing
    }

    var canRefresh: Bool { state == .loaded || state == .failed }
    var canSave: Bool {
        if case .loaded = detailState { return true }
        return false
    }
    var canDelete: Bool {
        if case .loaded = detailState { return true }
        return false
    }

    func matchPattern() -> Data? {
        Self.matchPattern(for: searchText)
    }

    static func matchPattern(for text: String) -> Data? {
        GlobPattern.matchPattern(for: text)
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
        detailState = .idle
        detailGeneration &+= 1
        preserveTTL = false
        isSaving = false
        isDeleting = false
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
            detailState = .idle
            detailGeneration &+= 1
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
        if key == nil {
            detailState = .idle
            detailGeneration &+= 1
            preserveTTL = false
            isSaving = false
            isDeleting = false
        }
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
        detailState = .idle
        detailGeneration = 0
        preserveTTL = false
        isSaving = false
        isDeleting = false
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

    // MARK: - Detail

    @discardableResult
    func prepareDetailLoad(for key: Data) -> UInt64 {
        detailGeneration &+= 1
        detailState = .loading(key: key)
        preserveTTL = false
        isSaving = false
        isDeleting = false
        return detailGeneration
    }

    func applyDetail(value: Data?, ttl: TTLState, key: Data, generation: UInt64) {
        guard generation == detailGeneration else { return }
        if let value {
            detailState = .loaded(key: key, value: value, ttl: ttl)
            preserveTTL = ttlIsExpiring(ttl)
        } else {
            detailState = .missing(key: key)
            preserveTTL = false
        }
    }

    func applyDetailFailure(_ error: Error, key: Data, generation: UInt64) {
        guard generation == detailGeneration else { return }
        let message: String
        if let kv = error as? KVClientError, case .serverError(let data) = kv {
            message = String(decoding: data, as: UTF8.self)
        } else {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        detailState = .failed(key: key, message: message)
        preserveTTL = false
    }

    func loadDetail(for key: Data, using client: KVClient) async {
        let gen = prepareDetailLoad(for: key)
        do {
            async let value = client.get(key)
            async let ttlState = client.ttl(key)
            let (v, t) = try await (value, ttlState)
            guard gen == detailGeneration else { return }
            applyDetail(value: v, ttl: t, key: key, generation: gen)
        } catch {
            guard gen == detailGeneration else { return }
            applyDetailFailure(error, key: key, generation: gen)
        }
    }

    func save(value newValue: Data, using client: KVClient) async {
        guard case .loaded(let key, _, _) = detailState else { return }
        let gen = detailGeneration
        isSaving = true
        defer { isSaving = false }
        do {
            let ttlState = try await client.ttl(key)
            guard gen == detailGeneration else { return }
            switch ttlState {
            case .missing:
                detailState = .missing(key: key)
                preserveTTL = false
                return
            case .expiring(let seconds) where seconds <= 0:
                detailState = .failed(key: key, message: "Key expired during editing — TTL reached zero; not saved")
                preserveTTL = false
                return
            case .persistent, .expiring:
                break
            }
            let expiration: SetExpiration?
            if preserveTTL {
                switch ttlState {
                case .expiring(let seconds) where seconds > 0:
                    expiration = .seconds(seconds)
                case .persistent:
                    expiration = nil
                case .missing, .expiring:
                    expiration = nil
                }
            } else {
                expiration = nil
            }
            try await client.set(key: key, value: newValue, expiration: expiration)
            guard gen == detailGeneration else { return }
            async let refreshedValue = client.get(key)
            async let refreshedTTL = client.ttl(key)
            let (v, t) = try await (refreshedValue, refreshedTTL)
            guard gen == detailGeneration else { return }
            if let v {
                detailState = .loaded(key: key, value: v, ttl: t)
                preserveTTL = ttlIsExpiring(t)
            } else {
                detailState = .missing(key: key)
                preserveTTL = false
            }
        } catch {
            guard gen == detailGeneration else { return }
            let message: String
            if let kv = error as? KVClientError, case .serverError(let data) = kv {
                message = String(decoding: data, as: UTF8.self)
            } else {
                message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            detailState = .failed(key: key, message: message)
        }
    }

    private func ttlIsExpiring(_ ttl: TTLState) -> Bool {
        if case .expiring = ttl { return true }
        return false
    }

    // MARK: - Delete

    nonisolated static func deletePreview(for key: Data, maxLength: Int = 64) -> String {
        if key.isEmpty { return "(empty)" }
        let raw: String
        if let s = ValuePresentation.textString(from: key) {
            raw = s
        } else {
            raw = ValuePresentation.hexString(from: key)
        }
        if raw.count <= maxLength { return raw }
        let ellipsis = "…"
        let keep = maxLength - ellipsis.count
        let prefixCount = keep / 2
        let suffixCount = keep - prefixCount
        return String(raw.prefix(prefixCount)) + ellipsis + String(raw.suffix(suffixCount))
    }

    func deleteKey(_ key: Data, using client: KVClient) async throws {
        isDeleting = true
        defer { isDeleting = false }
        _ = try await client.delete([key])
        keys.removeAll { $0 == key }
        if selection == key {
            selection = nil
            detailState = .idle
            detailGeneration &+= 1
            preserveTTL = false
            isSaving = false
        }
        do {
            let size = try await client.dbSize()
            dbsize = size
        } catch {
            // best-effort
        }
    }

    // MARK: - New Key

    func createKey(key: Data, value: Data, expiration: SetExpiration?, using client: KVClient) async throws {
        guard !key.isEmpty else { throw BrowserNewKeyError.emptyKey }
        try await client.set(key: key, value: value, expiration: expiration)
        if !keys.contains(key) {
            keys.append(key)
        }
        selection = key
        do {
            let size = try await client.dbSize()
            dbsize = size
        } catch {
            // DBSIZE refresh is best-effort; creation already succeeded
        }
    }
}
