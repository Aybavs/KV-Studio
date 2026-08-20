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
        isRecording = handle != nil
    }

    let isRecording: Bool

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
            guard let self, let data = self.read(from: handle) else { return }
            if data.isEmpty {
                self.complete(closingDescriptor: true)
            } else {
                self.consume(data)
            }
        }
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    // Detached so a cancelled caller still gives the pipe its chance to reach EOF.
    func waitUntilFinished(within budget: Duration) async {
        await Task.detached(priority: .userInitiated) { [self] in
            let deadline = ContinuousClock.now.advanced(by: budget)
            while !isFinished && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }.value
    }

    func finish() {
        complete(closingDescriptor: false)
    }

    // Only the handler ever reads or closes, and only under the lock, so the descriptor cannot be
    // closed out from under an in-flight read.
    private func read(from handle: FileHandle) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        return handle.availableData
    }

    private func complete(closingDescriptor: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let tail = buffer
        buffer = Data()
        if closingDescriptor { try? handle.close() }
        lock.unlock()

        handle.readabilityHandler = nil
        if !tail.isEmpty { onLine(String(decoding: tail, as: UTF8.self)) }
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
