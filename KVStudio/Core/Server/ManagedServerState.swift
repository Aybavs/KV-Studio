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
    var probe: Duration
    var gracefulShutdown: Duration
    var forcedShutdown: Duration
    var outputDrain: Duration
    var exitPoll: Duration = .seconds(1)

    // kv-server's own --shutdown-timeout defaults to 10s; the remainder is UI grace.
    static let `default` = ManagedServerTimeouts(
        readiness: .seconds(20),
        readinessPoll: .milliseconds(50),
        probe: .seconds(5),
        gracefulShutdown: .seconds(12),
        forcedShutdown: .seconds(3),
        outputDrain: .seconds(2),
        exitPoll: .seconds(1)
    )
}
