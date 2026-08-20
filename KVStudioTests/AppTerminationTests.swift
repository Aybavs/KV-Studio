import AppKit
import Testing
@testable import KV_Studio

@MainActor
private final class EventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

@MainActor
@Suite
struct AppTerminationTests {

    @Test func defersTerminationUntilShutdownFinishes() async {
        let delegate = AppDelegate()
        let log = EventLog()

        await withCheckedContinuation { continuation in
            delegate.shutDown = {
                log.record("shutdown began")
                try? await Task.sleep(for: .milliseconds(50))
                log.record("shutdown finished")
            }
            delegate.replyToTermination = { _ in
                log.record("replied")
                continuation.resume()
            }
            #expect(delegate.beginTermination() == .terminateLater)
            // Returning without having replied is what buys shutDown its time to run.
            #expect(log.events.contains("replied") == false)
        }

        #expect(log.events == ["shutdown began", "shutdown finished", "replied"])
    }

    @Test func repliesThatTerminationMayProceed() async {
        let delegate = AppDelegate()
        var allowed: Bool?

        await withCheckedContinuation { continuation in
            delegate.shutDown = {}
            delegate.replyToTermination = { value in
                allowed = value
                continuation.resume()
            }
            _ = delegate.beginTermination()
        }

        #expect(allowed == true)
    }

    @Test func terminatesImmediatelyWhenThereIsNothingToShutDown() {
        let delegate = AppDelegate()
        #expect(delegate.beginTermination() == .terminateNow)
    }
}
