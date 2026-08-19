import Foundation
import Darwin
import Testing
@testable import KV_Studio

@Suite(.timeLimit(.minutes(1)))
struct ProcessOutputDrainTests {

    // An undrained pipe blocks the child at ~64KB; this fixture writes far more than that.
    @Test func drainsMoreThanOnePipeBufferWithoutBlockingTheChild() async throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let script = try await fixtures.launchableScript(named: "noisy", body: FixtureScript.floodsStandardError)
        let logFile = fixtures.directory.appendingPathComponent("kv-server.log")

        let sink = ServerLogSink(url: logFile)
        let lines = LineCollector()

        let process = Process()
        process.executableURL = script
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let pid = process.processIdentifier
        defer { kill(pid, SIGKILL) }

        let drain = ProcessOutputDrain(reading: errorPipe.fileHandleForReading, sink: sink) { lines.append($0) }

        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!process.isRunning)
        #expect(process.terminationStatus == 0)

        while !lines.snapshot().contains(where: { $0.contains("DRAIN-SENTINEL") }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        drain.finish()
        sink.close()

        let collected = lines.snapshot()
        #expect(collected.count >= 4001)
        #expect(collected.last == "DRAIN-SENTINEL")

        let written = try Data(contentsOf: logFile)
        #expect(written.count > 300_000)
        #expect(String(decoding: written.suffix(64), as: UTF8.self).contains("DRAIN-SENTINEL"))
    }

    @Test func appendsToAnExistingLogFile() throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let logFile = fixtures.directory.appendingPathComponent("kv-server.log")
        try Data("earlier\n".utf8).write(to: logFile)

        let sink = ServerLogSink(url: logFile)
        sink.append(Data("later\n".utf8))
        sink.close()

        #expect(try String(contentsOf: logFile, encoding: .utf8) == "earlier\nlater\n")
    }

    @Test func emitsATrailingPartialLineOnFinish() async throws {
        let fixtures = try ProcessFixtures()
        defer { fixtures.remove() }
        let logFile = fixtures.directory.appendingPathComponent("kv-server.log")
        let sink = ServerLogSink(url: logFile)
        let lines = LineCollector()

        let pipe = Pipe()
        let drain = ProcessOutputDrain(reading: pipe.fileHandleForReading, sink: sink) { lines.append($0) }
        try pipe.fileHandleForWriting.write(contentsOf: Data("complete\nincomplete".utf8))
        try pipe.fileHandleForWriting.close()

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while lines.snapshot().count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        drain.finish()
        sink.close()

        #expect(lines.snapshot() == ["complete", "incomplete"])
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
