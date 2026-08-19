import Foundation

final class ServerLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.write(contentsOf: data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}

// An undrained pipe fills its kernel buffer and blocks the child on its next write.
final class ProcessOutputDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let sink: ServerLogSink
    private let onLine: @Sendable (String) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false

    private static let maximumPartialLine = 1 << 20

    init(reading handle: FileHandle, sink: ServerLogSink, onLine: @escaping @Sendable (String) -> Void) {
        self.handle = handle
        self.sink = sink
        self.onLine = onLine
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                self.finish()
            } else {
                self.consume(data)
            }
        }
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let tail = buffer
        buffer = Data()
        lock.unlock()

        handle.readabilityHandler = nil
        if !tail.isEmpty { onLine(String(decoding: tail, as: UTF8.self)) }
        try? handle.close()
    }

    private func consume(_ data: Data) {
        sink.append(data)

        var lines: [String] = []
        lock.lock()
        if !finished {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > Self.maximumPartialLine { buffer.removeAll(keepingCapacity: false) }
        }
        lock.unlock()

        for line in lines { onLine(line) }
    }
}
