import Foundation

enum BoundedConnectionError: Error, Equatable, Sendable {
    case timedOut(Duration)
}

// KVConnection deliberately has no read timeout, so a peer that accepts and never replies would
// park forever. Cancelling the connection from the timeout arm is what unparks it.
enum BoundedConnection {

    private enum Arm<T: Sendable>: Sendable {
        case value(T)
        case expired
    }

    static func withConnection<T: Sendable>(
        to endpoint: ConnectionEndpoint,
        within budget: Duration,
        _ body: @escaping @Sendable (KVConnection) async throws -> T
    ) async throws -> T {
        let connection = KVConnection()
        let abandoned = Abandonment()

        do {
            let value = try await withThrowingTaskGroup(of: Arm<T>.self) { group in
                group.addTask {
                    do {
                        try await connection.connect(to: endpoint)
                        // The flag is raised before the disconnect, so a connection established
                        // after that disconnect still sees it and tears itself down.
                        guard !abandoned.isRaised else {
                            await connection.disconnect()
                            throw BoundedConnectionError.timedOut(budget)
                        }
                        return .value(try await body(connection))
                    } catch {
                        if abandoned.isRaised { throw BoundedConnectionError.timedOut(budget) }
                        throw error
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: budget)
                    abandoned.raise()
                    await connection.disconnect()
                    return .expired
                }

                var outcome: Arm<T>?
                while let next = try await group.next() {
                    if case .value = next {
                        outcome = next
                        break
                    }
                }
                group.cancelAll()
                guard case .value(let value)? = outcome else {
                    throw BoundedConnectionError.timedOut(budget)
                }
                return value
            }
            await connection.disconnect()
            return value
        } catch {
            await connection.disconnect()
            throw error
        }
    }
}

private final class Abandonment: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }
}
