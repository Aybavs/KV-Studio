import Foundation
import Network

/// Owns one TCP socket. RESP2 matches replies to requests by position only, so every
/// write→read pair runs to completion before the next one starts.
actor KVConnection {

    private let queue = DispatchQueue(label: "dev.kvstudio.connection")

    private var connection: NWConnection?
    private var decoder = RESPDecoder()
    private var ready = false

    private var commandInFlight = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init() {}

    var isConnected: Bool { ready }

    func connect(to endpoint: ConnectionEndpoint) async throws {
        try Task.checkCancellation()
        await acquireCommandSlot()
        defer { releaseCommandSlot() }

        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw ConnectionError.invalidPort(endpoint.port)
        }

        teardown()
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        self.connection = connection

        do {
            try await start(connection)
        } catch {
            invalidate(connection)
            throw error
        }
        ready = true
    }

    func disconnect() async {
        teardown()
    }

    func send(_ arguments: [Data]) async throws -> RESPValue {
        try Task.checkCancellation()
        await acquireCommandSlot()
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

    private func acquireCommandSlot() async {
        guard commandInFlight else {
            commandInFlight = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
        }
    }

    // Hands ownership straight to the next waiter; `commandInFlight` never drops in between.
    private func releaseCommandSlot() {
        if waiting.isEmpty {
            commandInFlight = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: - Transport

    private func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ReadyBox(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.succeed()
                case .waiting(let error), .failed(let error):
                    box.fail(.connectFailed(String(describing: error)))
                case .cancelled:
                    box.fail(.connectionClosed)
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

    private func teardown() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        decoder = RESPDecoder()
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
