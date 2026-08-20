import Foundation
import Observation

@MainActor
@Observable
final class LogsViewModel {
    var filter: String = "" {
        didSet { applyFilter() }
    }
    private(set) var visibleEntries: [LogLine] = []

    @ObservationIgnored private let store: LogStore

    init(store: LogStore) {
        self.store = store
        applyFilter()
    }

    func append(_ text: String) {
        store.append(text)
        applyFilter()
    }

    // Clears the UI buffer only; the server's log file on disk is untouched.
    func clear() {
        store.clear()
        applyFilter()
    }

    func ingest(_ lines: AsyncStream<String>) async {
        for await line in lines {
            append(line)
        }
    }

    private func applyFilter() {
        visibleEntries = store.filtered(by: filter)
    }
}
