import Foundation

struct CompatibilityProbe: Sendable {

    private let budget: Duration

    init(budget: Duration = .seconds(5)) {
        self.budget = budget
    }

    func run(against endpoint: ConnectionEndpoint) async throws -> CompatibilityOutcome {
        let reached = ReachedStep()
        do {
            return try await BoundedConnection.withConnection(to: endpoint, within: budget) { connection in
                try await Self.probe(KVClient(connection: connection), reached: reached)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A cancelled probe unparks through the same timeout arm; it is not a slow server.
            try Task.checkCancellation()
            return Self.outcome(for: error, at: reached.step, within: budget)
        }
    }

    private static func probe(_ client: KVClient, reached: ReachedStep) async throws -> CompatibilityOutcome {
        reached.advance(to: .ping)
        do {
            try await client.ping()
        } catch let error as KVClientError {
            return incompatible(error, at: .ping)
        }

        reached.advance(to: .dbSize)
        do {
            _ = try await client.dbSize()
        } catch let error as KVClientError {
            return incompatible(error, at: .dbSize)
        }

        reached.advance(to: .scan)
        do {
            _ = try await client.scan(cursor: 0, match: nil, count: 1)
        } catch let error as KVClientError {
            return incompatible(error, at: .scan)
        }

        return .compatible
    }

    private static func incompatible(_ error: KVClientError, at step: ProbeStep) -> CompatibilityOutcome {
        switch error {
        case .serverError(let message):
            let text = String(decoding: message, as: UTF8.self)
            return .incompatible(
                step: step,
                reason: .serverError(class: ServerErrorClass(message: text), message: text)
            )
        case .unexpectedReply(let reply):
            return .incompatible(step: step, reason: .unexpectedReply(reply))
        }
    }

    private static func outcome(
        for error: any Error,
        at step: ProbeStep?,
        within budget: Duration
    ) -> CompatibilityOutcome {
        guard let step else {
            switch error {
            case is BoundedConnectionError:
                return .unreachable(.timedOut(budget))
            case let error as ConnectionError:
                return .unreachable(unreachable(from: error))
            default:
                return .unreachable(.connectFailed(String(describing: error)))
            }
        }

        switch error {
        case is BoundedConnectionError:
            return .protocolFailure(step: step, reason: .timedOut(budget))
        case let error as ConnectionError:
            return .protocolFailure(step: step, reason: protocolFailure(from: error))
        default:
            return .protocolFailure(step: step, reason: .transportFailure(String(describing: error)))
        }
    }

    private static func protocolFailure(from error: ConnectionError) -> ProtocolFailureReason {
        switch error {
        case .protocolViolation(let violation):
            return .malformedReply(violation)
        case .connectionClosed, .notConnected:
            return .connectionClosed
        case .transportFailure(let detail), .connectFailed(let detail):
            return .transportFailure(detail)
        case .invalidPort(let port):
            return .transportFailure("invalid port \(port)")
        }
    }

    private static func unreachable(from error: ConnectionError) -> UnreachableReason {
        switch error {
        case .invalidPort(let port):
            return .invalidPort(port)
        case .connectFailed(let detail):
            return .connectFailed(detail)
        default:
            return .connectFailed(error.errorDescription ?? String(describing: error))
        }
    }
}

// nil until the connection is up: a failure before that is a failure to reach the server at all.
private final class ReachedStep: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProbeStep?

    var step: ProbeStep? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(to step: ProbeStep) {
        lock.lock()
        value = step
        lock.unlock()
    }
}
