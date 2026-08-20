import AppKit

// willTerminate fires as the process is already leaving, so an unawaited Task there never runs.
// terminateLater holds the quit open until shutDown has actually finished.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shutDown: (@MainActor () async -> Void)?
    var replyToTermination: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginTermination()
    }

    func beginTermination() -> NSApplication.TerminateReply {
        guard let shutDown else { return .terminateNow }
        Task { @MainActor in
            await shutDown()
            replyToTermination(true)
        }
        return .terminateLater
    }
}
