import Foundation
import Network

// RESP2 matches replies to requests by position, so one write→read pair runs at a time.
actor KVConnection {

    private let queue = DispatchQueue(label: "dev.kvstudio.connection")

    private var connection: NWConnection?
    private var decoder = RESPDecoder()
    private var ready = false
    private var pendingReady: ReadyBox?

    private enum SlotOutcome {
        case acquired
        case cancelled
    }

    private var commandInFlight = false
    private var waiting: [UInt64] = []
    private var parked: [UInt64: CheckedContinuation<SlotOutcome, Never>] = [:]
    private var delivered: [UInt64: SlotOutcome] = [:]
    private var nextWaiterID: UInt64 = 0

    init() {}

    var isConnected: Bool { ready }

    func connect(to endpoint: ConnectionEndpoint) async throws {
        try Task.checkCancellation()
        try await acquireCommandSlot()
        defer { releaseCommandSlot() }

        try Task.checkCancellation()
        // NWEndpoint.Port accepts 0 as "any"; nothing listens there.
        guard endpoint.port != 0, let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw ConnectionError.invalidPort(endpoint.port)
        }

        teardown()
        decoder = RESPDecoder()
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        self.connection = connection

        do {
            try await start(connection)
        } catch {
            invalidate(connection)
            throw error
        }

        guard self.connection === connection else { throw ConnectionError.connectionClosed }
        ready = true
    }

    func disconnect() async {
        teardown()
    }

    func send(_ arguments: [Data]) async throws -> RESPValue {
        try Task.checkCancellation()
        try await acquireCommandSlot()
        defer { releaseCommandSlot() }

        try Task.checkCancellation()
        guard ready, let connection else { throw ConnectionError.notConnected }

        let value: RESPValue
        do {
            try await write(RESPEncoder.encodeCommand(arguments), on: connection)
            value = try await readReply(on: connection)
        } catch {
            invalidate(connection)
            throw error
        }

        // The reply is fully consumed, so discarding it here leaves the stream aligned.
        try Task.checkCancellation()
        return value
    }

    // MARK: - Serialization

    private func acquireCommandSlot() async throws {
        guard commandInFlight else {
            commandInFlight = true
            return
        }

        let id = nextWaiterID
        nextWaiterID += 1
        waiting.append(id)

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SlotOutcome, Never>) in
                if let early = delivered.removeValue(forKey: id) {
                    continuation.resume(returning: early)
                } else {
                    parked[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }

        if case .cancelled = outcome { throw CancellationError() }
    }

    // Hands ownership straight to the next waiter; `commandInFlight` never drops in between.
    private func releaseCommandSlot() {
        guard !waiting.isEmpty else {
            commandInFlight = false
            return
        }
        deliver(.acquired, to: waiting.removeFirst())
    }

    // A waiter that already left the queue owns the slot and releases it itself.
    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiting.firstIndex(of: id) else { return }
        waiting.remove(at: index)
        deliver(.cancelled, to: id)
    }

    private func deliver(_ outcome: SlotOutcome, to id: UInt64) {
        if let continuation = parked.removeValue(forKey: id) {
            continuation.resume(returning: outcome)
        } else {
            delivered[id] = outcome
        }
    }

    // MARK: - Transport

    private func start(_ connection: NWConnection) async throws {
        defer { pendingReady = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ReadyBox(continuation)
            pendingReady = box
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                switch state {
                case .ready:
                    box.succeed()
                case .waiting(let error):
                    box.fail(.connectFailed(String(describing: error)))
                case .failed(let error):
                    box.fail(.connectFailed(String(describing: error)))
                    if let self, let connection { Task { await self.invalidate(connection) } }
                case .cancelled:
                    box.fail(.connectionClosed)
                    if let self, let connection { Task { await self.invalidate(connection) } }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func write(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ConnectionError.transportFailure(String(describing: error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func readReply(on connection: NWConnection) async throws -> RESPValue {
        while true {
            do {
                if let value = try decoder.nextValue() { return value }
            } catch let error as RESPError {
                throw ConnectionError.protocolViolation(error)
            }
            guard let chunk = try await receive(on: connection) else {
                throw ConnectionError.connectionClosed
            }
            guard !chunk.isEmpty else {
                throw ConnectionError.transportFailure("receive delivered no bytes")
            }
            decoder.append(chunk)
        }
    }

    // No cancellation handler: an in-flight reply must be drained, not abandoned mid-frame.
    private func receive(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: ConnectionError.transportFailure(String(describing: error)))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func invalidate(_ connection: NWConnection) {
        guard self.connection === connection else { return }
        teardown()
    }

    // The decoder survives on purpose, so a doomed reader reports a transport error; `connect` replaces it.
    private func teardown() {
        pendingReady?.fail(.connectionClosed)
        pendingReady = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        ready = false
    }
}

// NWConnection reports readiness through repeated state callbacks; only the first one counts.
private final class ReadyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func succeed() {
        take()?.resume()
    }

    func fail(_ error: ConnectionError) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}
