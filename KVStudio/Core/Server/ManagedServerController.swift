import Darwin
import Foundation

actor ManagedServerController {

    private struct Child {
        let pid: pid_t
        let identity: ProcessStartTime
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
            currentState = .failed(Self.message(for: error))
            throw error
        }
    }

    private func launchOrAdopt() async throws -> pid_t {
        do {
            try paths.createDirectoryTree()
        } catch {
            throw ManagedServerError.storageUnavailable(error.localizedDescription)
        }

        let settings = preferences.loadPreferences()
        let endpoint = ConnectionEndpoint(host: settings.localBindHost, port: settings.localPort)

        if let adopted = try await reconcileRecord(against: endpoint) { return adopted }

        let binary = try resolver.resolve(in: paths)
        if await Self.acceptsConnections(endpoint, within: timeouts.probe) {
            throw ManagedServerError.portInUse(endpoint)
        }

        return try await launch(binary: binary, on: endpoint)
    }

    // MARK: - Ownership

    // Adoption is what makes "exactly one managed server" survive a Studio crash.
    private func reconcileRecord(against endpoint: ConnectionEndpoint) async throws -> pid_t? {
        guard let record = records.load() else { return nil }

        guard !record.isIntent else {
            try await reclaimIntent(record)
            records.clear()
            return nil
        }

        guard record.identifiesLiveProcess, let pid = record.pid, let identity = record.processStartTime else {
            records.clear()
            return nil
        }

        if record.endpoint == endpoint, await Self.answersPing(endpoint, within: timeouts.probe) {
            child = Child(pid: pid, identity: identity, process: nil, endpoint: record.endpoint)
            return pid
        }

        // Wrong port or no longer answering, but the identity proves the process is ours: take it
        // back rather than abandon it and spawn a second server onto the same append-only file.
        try await reclaim(pid: pid, since: identity)
        records.clear()
        return nil
    }

    // An intent record names a spawn that may have outlived the Studio that started it.
    private func reclaimIntent(_ record: ManagedServerRecord) async throws {
        guard await Self.acceptsConnections(record.endpoint, within: timeouts.probe) else { return }

        let candidates = ProcessIdentity.pids(
            runningExecutableAt: record.binaryPath,
            startedNoEarlierThan: record.startedAt
        )
        guard !candidates.isEmpty else { return }
        guard candidates.count == 1, let pid = candidates.first,
              let identity = ProcessIdentity.startTime(of: pid) else {
            throw ManagedServerError.unreclaimedServer(record.endpoint)
        }
        try await reclaim(pid: pid, since: identity)
    }

    private func reclaim(pid: pid_t, since identity: ProcessStartTime) async throws {
        let outcome = await ManagedServerTerminator.terminate(
            pid: pid,
            since: identity,
            graceful: timeouts.gracefulShutdown,
            forced: timeouts.forcedShutdown
        )
        guard outcome != .stillRunning else { throw ManagedServerError.terminationFailed(pid) }
    }

    // MARK: - Launch

    private func launch(binary: URL, on endpoint: ConnectionEndpoint) async throws -> pid_t {
        let intent = ManagedServerRecord.intent(endpoint: endpoint, binaryPath: binary.path, startedAt: Date())
        do {
            try records.save(intent)
        } catch {
            throw ManagedServerError.storageUnavailable(error.localizedDescription)
        }

        let process = try spawn(binary: binary, endpoint: endpoint)
        let pid = process.processIdentifier

        guard let identity = ProcessIdentity.startTime(of: pid) else {
            let wasRunning = process.isRunning
            if wasRunning { process.terminate() }
            await closeOutput()
            records.clear()
            throw wasRunning
                ? ManagedServerError.launchFailed("no process identity for pid \(pid)")
                : ManagedServerError.exitedDuringStartup(process.terminationStatus)
        }
        child = Child(pid: pid, identity: identity, process: process, endpoint: endpoint)

        do {
            do {
                try records.save(intent.launched(pid: pid, processStartTime: identity))
            } catch {
                throw ManagedServerError.storageUnavailable(error.localizedDescription)
            }
            try await waitUntilReady(process: process, endpoint: endpoint)
        } catch {
            if await discardChild() == .stillRunning {
                throw ManagedServerError.terminationFailed(pid)
            }
            throw error
        }
        return pid
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
        // Losing the file is survivable, but it must not be silent.
        if !sink.isRecording {
            continuation.yield("kv-studio: log file unavailable at \(paths.logFile.path); showing live output only")
        }
        let drains = [standardOutput, standardError].map { pipe in
            ProcessOutputDrain(reading: pipe.fileHandleForReading, sink: sink) { continuation.yield($0) }
        }
        logSink = sink
        self.drains = drains

        do {
            try process.run()
        } catch {
            for drain in drains { drain.finish() }
            self.drains = []
            sink.close()
            logSink = nil
            records.clear()
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
            if await Self.answersPing(endpoint, within: timeouts.probe) { return }
            guard ContinuousClock.now < deadline else {
                throw ManagedServerError.readinessTimedOut(endpoint, timeouts.readiness)
            }
            try await Task.sleep(for: timeouts.readinessPoll)
        }
    }

    // MARK: - Stop

    private func performStop() async {
        let outcome = await discardChild()
        if outcome == .stillRunning, let child {
            currentState = .failed(Self.message(for: ManagedServerError.terminationFailed(child.pid)))
        } else {
            currentState = .stopped
        }
    }

    // A process that survived SIGKILL keeps its record: that record is the only way back to it.
    private func discardChild() async -> ManagedServerTerminationOutcome {
        guard let child else {
            await closeOutput()
            return .notRunning
        }

        let outcome = await ManagedServerTerminator.terminate(
            pid: child.pid,
            since: child.identity,
            graceful: timeouts.gracefulShutdown,
            forced: timeouts.forcedShutdown
        )
        guard outcome != .stillRunning else { return outcome }

        self.child = nil
        await closeOutput()
        records.clear()
        return outcome
    }

    private func closeOutput() async {
        for drain in drains { await drain.waitUntilFinished(within: timeouts.outputDrain) }
        for drain in drains { drain.finish() }
        drains = []
        logSink?.close()
        logSink = nil
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Probes

    private static func acceptsConnections(_ endpoint: ConnectionEndpoint, within budget: Duration) async -> Bool {
        await probe(endpoint, ping: false, within: budget)
    }

    private static func answersPing(_ endpoint: ConnectionEndpoint, within budget: Duration) async -> Bool {
        await probe(endpoint, ping: true, within: budget)
    }

    private static func probe(_ endpoint: ConnectionEndpoint, ping: Bool, within budget: Duration) async -> Bool {
        let reached: Void? = try? await BoundedConnection.withConnection(to: endpoint, within: budget) { connection in
            if ping { try await KVClient(connection: connection).ping() }
        }
        return reached != nil
    }

    deinit {
        for drain in drains { drain.finish() }
        logSink?.close()
        outputContinuation.finish()
        guard let child else { return }
        let (pid, identity) = (child.pid, child.identity)
        let graceful = timeouts.gracefulShutdown
        let forced = timeouts.forcedShutdown
        Task.detached {
            _ = await ManagedServerTerminator.terminate(pid: pid, since: identity, graceful: graceful, forced: forced)
        }
    }
}
