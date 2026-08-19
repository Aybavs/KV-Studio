import Darwin
import Foundation

enum ManagedServerState: Equatable, Sendable {
    case stopped
    case starting
    case running(pid_t)
    case stopping
    case failed(String)
}

struct ManagedServerTimeouts: Equatable, Sendable {
    var readiness: Duration
    var readinessPoll: Duration
    var gracefulShutdown: Duration
    var forcedShutdown: Duration

    // kv-server's own --shutdown-timeout defaults to 10s; the remainder is UI grace.
    static let `default` = ManagedServerTimeouts(
        readiness: .seconds(20),
        readinessPoll: .milliseconds(50),
        gracefulShutdown: .seconds(12),
        forcedShutdown: .seconds(3)
    )
}
