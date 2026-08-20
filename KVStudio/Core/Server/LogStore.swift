import Foundation

struct LogLine: Identifiable, Equatable, Sendable {
    let id: UInt64
    let text: String
}

// Persistence is ServerLogSink's job; this is only the bounded window the UI reads.
final class LogStore: @unchecked Sendable {
    let maxLines: Int
    let maxBytes: Int

    private let lock = NSLock()
    private var lines: [LogLine] = []
    private var bytes = 0
    private var nextID: UInt64 = 0

    init(maxLines: Int = 5_000, maxBytes: Int = 1_048_576) {
        self.maxLines = max(1, maxLines)
        self.maxBytes = max(1, maxBytes)
    }

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(LogLine(id: nextID, text: text))
        nextID &+= 1
        bytes += text.utf8.count
        // Stops at one line so a single oversized line is kept rather than evicted forever.
        while lines.count > 1 && (lines.count > maxLines || bytes > maxBytes) {
            bytes -= lines.removeFirst().text.utf8.count
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
        bytes = 0
    }

    var snapshot: [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func filtered(by query: String) -> [LogLine] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snapshot }
        return snapshot.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }
}
