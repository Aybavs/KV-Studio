import Darwin
import Foundation

actor ManagedServerController {

    private struct Child {
        let pid: pid_t
        let identity: ProcessStartTime?
        let process: Process?
        let endpoint: ConnectionEndpoint
    }

    private let paths: ManagedPaths
    private let preferences: PreferencesStore
    private let records: ManagedServerRecordStore
    private let resolver: ServerBinaryResolver
    private let timeouts: ManagedServerTimeouts

    nonisolated let outputLines: AsyncStream<String>
    private nonisolated let outputContinuation: AsyncStream<String>.Continuation

    private var currentState: ManagedServerState = .stopped
    private var child: Child?
    private var logSink: ServerLogSink?
    private var drains: [ProcessOutputDrain] = []
    private var startTask: Task<pid_t, Error>?
    private var stopTask: Task<Void, Never>?

    init(
        paths: ManagedPaths,
        resolver: ServerBinaryResolver = ServerBinaryResolver(),
        timeouts: ManagedServerTimeouts = .default
    ) {
        self.paths = paths
        self.preferences = PreferencesStore(paths: paths)
        self.records = ManagedServerRecordStore(paths: paths)
        self.resolver = resolver
        self.timeouts = timeouts
        (outputLines, outputContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4096))
    }

    var state: ManagedServerState { currentState }

    var endpoint: ConnectionEndpoint? { child?.endpoint }

    // MARK: - Lifecycle

    @discardableResult
    func start() async throws -> pid_t {
        while true {
            if let stopTask {
                await stopTask.value
                continue
            }
            if case .running(let pid) = currentState { return pid }
            if let startTask { return try await startTask.value }
            break
        }

        currentState = .starting
        let task = Task { () throws -> pid_t in
            defer { self.startTask = nil }
            return try await self.performStart()
        }
        startTask = task
        return try await task.value
    }

    func stop() async {
        while true {
            if let stopTask {
                await stopTask.value
                return
            }
            if let startTask {
                startTask.cancel()
                _ = try? await startTask.value
                continue
            }
            break
        }

        currentState = .stopping
        let task = Task {
            defer { self.stopTask = nil }
            await self.performStop()
        }
        stopTask = task
        await task.value
    }

    // MARK: - Start

    private func performStart() async throws -> pid_t {
        do {
            let pid = try await launchOrAdopt()
            currentState = .running(pid)
            return pid
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            currentState = .failed(message)
            throw error
        }
    }

    private func launchOrAdopt() async throws -> pid_t {
        do {
            try paths.createDirectoryTree()
        } catch {
            throw ManagedServerError.storageUnavailable(error.localizedDescription)
        }

        if let adopted = await adoptRecordedProcess() { return adopted }

        let settings = preferences.loadPreferences()
        let endpoint = ConnectionEndpoint(host: settings.localBindHost, port: settings.localPort)
        let binary = try resolver.resolve(in: paths)

        if await Self.acceptsConnections(endpoint) { throw ManagedServerError.portInUse(endpoint) }

        let process = try spawn(binary: binary, endpoint: endpoint)
        let pid = process.processIdentifier
        child = Child(pid: pid, identity: ProcessIdentity.startTime(of: pid), process: process, endpoint: endpoint)

        do {
            guard let identity = child?.identity else {
                throw process.isRunning
                    ? ManagedServerError.launchFailed("no process identity for pid \(pid)")
                    : ManagedServerError.exitedDuringStartup(process.terminationStatus)
            }
            do {
                try records.save(
                    ManagedServerRecord(
                        pid: pid,
                        host: endpoint.host,
                        port: endpoint.port,
                        binaryPath: binary.path,
                        processStartTime: identity,
                        startedAt: Date()
                    )
                )
            } catch {
                throw ManagedServerError.storageUnavailable(error.localizedDescription)
            }
            try await waitUntilReady(process: process, endpoint: endpoint)
        } catch {
            await releaseChild()
            throw error
        }
        return pid
    }

    // Adoption is what makes "exactly one managed server" survive a Studio crash.
    private func adoptRecordedProcess() async -> pid_t? {
        guard let record = records.load() else { return nil }
        guard record.identifiesLiveProcess, await Self.answersPing(record.endpoint) else {
            records.clear()
            return nil
        }
        child = Child(pid: record.pid, identity: record.processStartTime, process: nil, endpoint: record.endpoint)
        return record.pid
    }

    private func spawn(binary: URL, endpoint: ConnectionEndpoint) throws -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--host", endpoint.host,
            "--port", String(endpoint.port),
            "--appendonly",
            "--appendfilename", paths.aofFile.path,
            "--appendfsync", "everysec",
            "--loglevel", "info"
        ]

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError

        let sink = ServerLogSink(url: paths.logFile)
        let continuation = outputContinuation
        let drains = [standardOutput, standardError].map { pipe in
            ProcessOutputDrain(reading: pipe.fileHandleForReading, sink: sink) { continuation.yield($0) }
        }
        logSink = sink
        self.drains = drains

        do {
            try process.run()
        } catch {
            closeOutput()
            throw ManagedServerError.launchFailed(error.localizedDescription)
        }
        return process
    }

    private func waitUntilReady(process: Process, endpoint: ConnectionEndpoint) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeouts.readiness)
        while true {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw ManagedServerError.exitedDuringStartup(process.terminationStatus)
            }
            if await Self.answersPing(endpoint) { return }
            guard ContinuousClock.now < deadline else {
                throw ManagedServerError.readinessTimedOut(endpoint, timeouts.readiness)
            }
            try await Task.sleep(for: timeouts.readinessPoll)
        }
    }

    // MARK: - Stop

    private func performStop() async {
        await releaseChild()
        currentState = .stopped
    }

    private func releaseChild() async {
        if let child {
            _ = await ManagedServerTerminator.terminate(
                pid: child.pid,
                since: child.identity,
                graceful: timeouts.gracefulShutdown,
                forced: timeouts.forcedShutdown
            )
        }
        child = nil
        closeOutput()
        records.clear()
    }

    private func closeOutput() {
        for drain in drains { drain.finish() }
        drains = []
        logSink?.close()
        logSink = nil
    }

    // MARK: - Probes

    private static func acceptsConnections(_ endpoint: ConnectionEndpoint) async -> Bool {
        let connection = KVConnection()
        let connected = (try? await connection.connect(to: endpoint)) != nil
        await connection.disconnect()
        return connected
    }

    private static func answersPing(_ endpoint: ConnectionEndpoint) async -> Bool {
        let connection = KVConnection()
        var answered = false
        if (try? await connection.connect(to: endpoint)) != nil {
            answered = (try? await KVClient(connection: connection).ping()) != nil
        }
        await connection.disconnect()
        return answered
    }
}
