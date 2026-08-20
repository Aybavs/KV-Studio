import Testing
import Foundation
@testable import KV_Studio

@Suite
struct LogsAutoscrollTests {

    @Test func autoscrollEnabledAndNotPausedShouldScroll() {
        var state = LogsAutoscrollState(isAutoscrollEnabled: true, isPaused: false)
        #expect(state.shouldAutoscroll == true)
    }

    @Test func pausedPreventsAutoscrollEvenWhenEnabled() {
        var state = LogsAutoscrollState(isAutoscrollEnabled: true, isPaused: true)
        #expect(state.shouldAutoscroll == false)
    }

    @Test func disabledAutoscrollPreventsScrollWhenNotPaused() {
        var state = LogsAutoscrollState(isAutoscrollEnabled: false, isPaused: false)
        #expect(state.shouldAutoscroll == false)
    }

    @Test func togglingPauseFlipsAutoscroll() {
        var state = LogsAutoscrollState(isAutoscrollEnabled: true, isPaused: false)
        state.isPaused.toggle()
        #expect(state.shouldAutoscroll == false)
        state.isPaused.toggle()
        #expect(state.shouldAutoscroll == true)
    }
}

@Suite
struct LogsAvailabilityTests {

    @Test func managedPhaseIsConsideredAvailable() {
        let phase: ConnectionPhase = .connected(ConnectionSession(target: .managedLocal, endpoint: ConnectionEndpoint(host: "127.0.0.1", port: 6380)))
        #expect(LogsAvailability.isManaged(phase: phase) == true)
    }

    @Test func existingPhaseIsConsideredUnavailable() {
        let endpoint = ConnectionEndpoint(host: "10.0.0.5", port: 6380)
        let phase: ConnectionPhase = .connected(ConnectionSession(target: .existing(endpoint), endpoint: endpoint))
        #expect(LogsAvailability.isManaged(phase: phase) == false)
    }

    @Test func disconnectedIsConsideredManagedForLogs() {
        #expect(LogsAvailability.isManaged(phase: .disconnected) == true)
    }
}

@Suite
@MainActor
struct LogsIngestTests {

    private final class CapturingHost: ManagedServerHosting, @unchecked Sendable {
        let lines: AsyncStream<String>
        init(lines: AsyncStream<String>) { self.lines = lines }
        var outputLines: AsyncStream<String> { lines }
        func start() async throws -> ManagedServerHandle { throw ManagedServerError.binaryUnavailable([]) }
        func stop() async -> ManagedServerStopOutcome { .stopped }
    }

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kv-logs-ingest-\(UUID().uuidString)", isDirectory: true)
        let paths = ManagedPaths(root: root)
        try paths.createDirectoryTree()
        return paths
    }

    @Test func coordinatorStreamReachesViewModel() async throws {
        let (stream, cont) = AsyncStream<String>.makeStream()
        cont.yield("hello")
        cont.yield("world")
        cont.finish()
        let host = CapturingHost(lines: stream)
        let paths = try makePaths()
        let coordinator = ConnectionCoordinator(paths: paths, server: host)
        let model = LogsViewModel(store: LogStore(maxLines: 100, maxBytes: 10_000))
        await model.ingest(coordinator.outputLines)
        #expect(model.visibleEntries.map(\.text) == ["hello", "world"])
    }

    @Test func ingestRespectsActiveFilter() async throws {
        let (stream, cont) = AsyncStream<String>.makeStream()
        cont.yield("keep this")
        cont.yield("drop this")
        cont.yield("keep that")
        cont.finish()
        let host = CapturingHost(lines: stream)
        let paths = try makePaths()
        let coordinator = ConnectionCoordinator(paths: paths, server: host)
        let model = LogsViewModel(store: LogStore(maxLines: 100, maxBytes: 10_000))
        model.filter = "keep"
        await model.ingest(coordinator.outputLines)
        #expect(model.visibleEntries.map(\.text) == ["keep this", "keep that"])
    }

    @Test func emptyStreamYieldsNothing() async throws {
        let (stream, cont) = AsyncStream<String>.makeStream()
        cont.finish()
        let host = CapturingHost(lines: stream)
        let paths = try makePaths()
        let coordinator = ConnectionCoordinator(paths: paths, server: host)
        let model = LogsViewModel(store: LogStore(maxLines: 100, maxBytes: 10_000))
        await model.ingest(coordinator.outputLines)
        #expect(model.visibleEntries.isEmpty)
    }

    @Test func filterStillAppliesAfterIngest() async throws {
        let (stream, cont) = AsyncStream<String>.makeStream()
        cont.yield("INFO listening")
        cont.yield("ERROR boom")
        cont.finish()
        let host = CapturingHost(lines: stream)
        let paths = try makePaths()
        let coordinator = ConnectionCoordinator(paths: paths, server: host)
        let model = LogsViewModel(store: LogStore(maxLines: 100, maxBytes: 10_000))
        await model.ingest(coordinator.outputLines)
        model.filter = "error"
        #expect(model.visibleEntries.map(\.text) == ["ERROR boom"])
        model.filter = ""
        #expect(model.visibleEntries.count == 2)
    }
}
