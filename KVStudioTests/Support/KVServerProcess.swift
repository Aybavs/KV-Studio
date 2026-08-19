import Foundation
import Darwin
import Testing
@testable import KV_Studio

enum KVServerBinaryLocator {
    static func find() -> URL? {
        if let override = ProcessInfo.processInfo.environment["KV_SERVER_BINARY"] {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = repoRoot.appendingPathComponent(".build/kv-server")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    static var skipComment: Comment {
        "kv-server binary not found; run scripts/build-test-backend.sh or set KV_SERVER_BINARY"
    }
}

enum KVServerProcessError: Error {
    case portAllocationFailed
    case processExitedBeforeReady(Int32)
    case readinessTimedOut
}

// Launches the real kv-server binary on an OS-allocated port for integration tests.
final class KVServerProcess: @unchecked Sendable {
    let endpoint: ConnectionEndpoint

    private let process: Process
    private let workDirectory: URL
    private let exited = Signal()
    private let lock = NSLock()
    private var reaped = false

    private init(process: Process, endpoint: ConnectionEndpoint, workDirectory: URL) {
        self.process = process
        self.endpoint = endpoint
        self.workDirectory = workDirectory
    }

    static func start(binary: URL) async throws -> KVServerProcess {
        let port = try allocatePort()
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-host", "127.0.0.1",
            "-port", String(port),
            "-appendonly",
            "-appendfilename", workDirectory.appendingPathComponent("appendonly.aof").path,
            "-loglevel", "error"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let instance = KVServerProcess(
            process: process,
            endpoint: ConnectionEndpoint(host: "127.0.0.1", port: port),
            workDirectory: workDirectory
        )
        process.terminationHandler = { [exited = instance.exited] _ in exited.fire() }

        try process.run()

        do {
            try await instance.waitUntilReady()
        } catch {
            await instance.terminate()
            throw error
        }
        return instance
    }

    private func waitUntilReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            guard process.isRunning else {
                throw KVServerProcessError.processExitedBeforeReady(process.terminationStatus)
            }
            let connection = KVConnection()
            if (try? await connection.connect(to: endpoint)) != nil {
                let client = KVClient(connection: connection)
                if (try? await client.ping()) != nil {
                    await connection.disconnect()
                    return
                }
            }
            await connection.disconnect()
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw KVServerProcessError.readinessTimedOut
    }

    func terminate() async {
        guard markReapedIfNeeded() else { return }

        if process.isRunning {
            process.terminate()
            if await !waitForExit(timeout: .seconds(5)) {
                kill(process.processIdentifier, SIGKILL)
                _ = await waitForExit(timeout: .seconds(5))
            }
        }
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func markReapedIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !reaped else { return false }
        reaped = true
        return true
    }

    private func waitForExit(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.exited.wait(); return true }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    deinit {
        lock.lock()
        let alreadyReaped = reaped
        lock.unlock()
        guard !alreadyReaped, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    private static func allocatePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw KVServerProcessError.portAllocationFailed }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw KVServerProcessError.portAllocationFailed }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { throw KVServerProcessError.portAllocationFailed }
        return UInt16(bigEndian: assigned.sin_port)
    }
}

func withKVServer<T>(
    binary: URL,
    _ body: (KVServerProcess) async throws -> T
) async throws -> T {
    let server = try await KVServerProcess.start(binary: binary)
    do {
        let result = try await body(server)
        await server.terminate()
        return result
    } catch {
        await server.terminate()
        throw error
    }
}
