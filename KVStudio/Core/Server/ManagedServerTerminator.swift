import Darwin
import Foundation

enum ManagedServerTerminationOutcome: Equatable, Sendable {
    case notRunning
    case exitedGracefully
    case forced
    case stillRunning
}

enum ManagedServerTerminator {

    // Detached on purpose: a cancelled caller must not abandon a half-signalled process.
    static func terminate(
        pid: pid_t,
        since identity: ProcessStartTime?,
        graceful: Duration,
        forced: Duration
    ) async -> ManagedServerTerminationOutcome {
        await Task.detached(priority: .userInitiated) {
            guard ProcessIdentity.isAlive(pid: pid, since: identity) else { return .notRunning }

            kill(pid, SIGTERM)
            if await waitForExit(pid: pid, since: identity, within: graceful) { return .exitedGracefully }

            guard ProcessIdentity.isAlive(pid: pid, since: identity) else { return .exitedGracefully }
            kill(pid, SIGKILL)
            return await waitForExit(pid: pid, since: identity, within: forced) ? .forced : .stillRunning
        }.value
    }

    private static func waitForExit(pid: pid_t, since identity: ProcessStartTime?, within budget: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: budget)
        while true {
            if !ProcessIdentity.isAlive(pid: pid, since: identity) { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
