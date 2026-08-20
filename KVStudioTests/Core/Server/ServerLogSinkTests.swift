import Foundation
import Testing
@testable import KV_Studio

@Suite
struct ServerLogSinkTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func reportsRecordingWhenTheFileOpens() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = ServerLogSink(url: directory.appendingPathComponent("kv-server.log"))
        defer { sink.close() }
        #expect(sink.isRecording)
    }

    @Test func reportsNotRecordingWhenTheFileCannotBeOpened() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A directory at the log's path makes FileHandle(forWritingTo:) fail the way a
        // permission problem would, without needing elevated privileges.
        let blocked = directory.appendingPathComponent("kv-server.log", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let sink = ServerLogSink(url: blocked)
        defer { sink.close() }
        #expect(sink.isRecording == false)
    }

    @Test func appendingWithoutAFileIsHarmless() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("kv-server.log", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let sink = ServerLogSink(url: blocked)
        defer { sink.close() }
        sink.append(Data("noise\n".utf8))
        #expect(sink.isRecording == false)
    }
}
