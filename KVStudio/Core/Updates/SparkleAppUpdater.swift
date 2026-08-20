import Foundation
import Observation
import Sparkle

// Sparkle checks and installs only when the user asks: automatic checking and automatic download
// are both refused here, and the plan forbids silent installation outright.
@MainActor
@Observable
final class SparkleAppUpdater: NSObject, AppUpdating, SPUUpdaterDelegate {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    func start(feedURL: URL?) {
        guard controller == nil, feedURL != nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        self.controller = controller
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }
}
