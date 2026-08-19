import Foundation
import Darwin
import Testing
@testable import KV_Studio

@Suite(
    .timeLimit(.minutes(3)),
    .enabled(if: KVServerBinaryLocator.find() != nil, KVServerBinaryLocator.skipComment)
)
struct ManagedServerLiveTests {

    private var binary: URL { KVServerBinaryLocator.find()! }

    private func makeController(port: UInt16? = nil) throws -> (ManagedServerController, ManagedPaths, UInt16) {
        let paths = ManagedPaths(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("kv-live-\(UUID().uuidString)", isDirectory: true)
        )
        try paths.createDirectoryTree()
        let port = try port ?? KVServerProcess.allocatePort()
        try PreferencesStore(paths: paths).savePreferences(
            Preferences(localBindHost: "127.0.0.1", localPort: port)
        )
        let resolver = ServerBinaryResolver(
            environment: [ServerBinaryResolver.overrideEnvironmentKey: binary.path],
            bundledBinary: nil
        )
        return (ManagedServerController(paths: paths, resolver: resolver), paths, port)
    }

    private func withManagedServer(
        port: UInt16? = nil,
        _ body: (ManagedServerController, ManagedPaths, UInt16) async throws -> Void
    ) async throws {
        let (controller, paths, port) = try makeController(port: port)
        do {
            try await body(controller, paths, port)
        } catch {
            await controller.stop()
            try? FileManager.default.removeItem(at: paths.root)
            throw error
        }
        await controller.stop()
        try? FileManager.default.removeItem(at: paths.root)
    }

    private func client(_ endpoint: ConnectionEndpoint) async throws -> KVClient {
        let connection = KVConnection()
        try await connection.connect(to: endpoint)
        return KVClient(connection: connection)
    }

    @Test func startsRunsAndStopsTheManagedServer() async throws {
        var stoppedPID: pid_t = 0
        try await withManagedServer { controller, paths, port in
            let pid = try await controller.start()
            stoppedPID = pid

            #expect(await controller.state == .running(pid))
            #expect(await controller.endpoint == ConnectionEndpoint(host: "127.0.0.1", port: port))
            try await client(ConnectionEndpoint(host: "127.0.0.1", port: port)).ping()

            let record = try #require(ManagedServerRecordStore(paths: paths).load())
            #expect(record.pid == pid)
            #expect(record.host == "127.0.0.1")
            #expect(record.port == port)
            #expect(record.binaryPath == binary.path)
            #expect(record.identifiesLiveProcess)

            await controller.stop()
            #expect(await controller.state == .stopped)
            #expect(await controller.endpoint == nil)
            #expect(ManagedServerRecordStore(paths: paths).load() == nil)
            #expect(!ProcessIdentity.isAlive(pid: pid, since: record.processStartTime))
        }
        #expect(!ProcessIdentity.isAlive(pid: stoppedPID, since: nil))
    }

    // The launch flags are verified by their effects: bind address, log level, and the AOF location.
    @Test func launchesWithTheConfiguredFlags() async throws {
        try await withManagedServer { controller, paths, port in
            _ = try await controller.start()
            let client = try await client(ConnectionEndpoint(host: "127.0.0.1", port: port))
            try await client.set(key: Data("flag-check".utf8), value: Data("value".utf8), expiration: nil)

            let aofDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < aofDeadline {
                if let size = try? Data(contentsOf: paths.aofFile).count, size > 0 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(try Data(contentsOf: paths.aofFile).count > 0)

            let log = try String(contentsOf: paths.logFile, encoding: .utf8)
            #expect(log.contains("level=INFO"))
            #expect(log.contains("addr=127.0.0.1:\(port)"))
        }
    }

    @Test func concurrentStartsProduceOneServer() async throws {
        try await withManagedServer { controller, paths, _ in
            async let first = controller.start()
            async let second = controller.start()
            let pids = try await [first, second]

            #expect(pids[0] == pids[1])
            #expect(await controller.state == .running(pids[0]))
            #expect(try #require(ManagedServerRecordStore(paths: paths).load()).pid == pids[0])
        }
    }

    @Test func startingTwiceInSequenceIsIdempotent() async throws {
        try await withManagedServer { controller, _, _ in
            let first = try await controller.start()
            let second = try await controller.start()
            #expect(first == second)
        }
    }

    // A crashed Studio leaves its server running; the next launch must take it back, not double it.
    @Test func adoptsAServerLeftBehindByAPreviousController() async throws {
        try await withManagedServer { controller, paths, port in
            let pid = try await controller.start()

            let resolver = ServerBinaryResolver(
                environment: [ServerBinaryResolver.overrideEnvironmentKey: binary.path],
                bundledBinary: nil
            )
            let successor = ManagedServerController(paths: paths, resolver: resolver)
            let adopted = try await successor.start()

            #expect(adopted == pid)
            #expect(await successor.state == .running(pid))
            #expect(await successor.endpoint == ConnectionEndpoint(host: "127.0.0.1", port: port))
            try await client(ConnectionEndpoint(host: "127.0.0.1", port: port)).ping()

            await successor.stop()
            #expect(!ProcessIdentity.isAlive(pid: pid, since: nil))
            #expect(ManagedServerRecordStore(paths: paths).load() == nil)
        }
    }

    // Port 6380 held by somebody else is Task 11's conflict flow, never ours to resolve by force.
    @Test func refusesToStartWhenAnotherServerOwnsThePort() async throws {
        try await withKVServer(binary: binary) { occupant in
            try await withManagedServer(port: occupant.endpoint.port) { controller, paths, port in
                let error = await #expect(throws: ManagedServerError.self) { try await controller.start() }
                #expect(error == .portInUse(ConnectionEndpoint(host: "127.0.0.1", port: port)))
                #expect(await controller.endpoint == nil)
                #expect(ManagedServerRecordStore(paths: paths).load() == nil)
                try await self.client(occupant.endpoint).ping()
            }
        }
    }
}
