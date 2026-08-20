import Foundation
import Observation
import Sparkle

// Sparkle checks and installs only when the user asks: automatic checking and automatic download
// are both refused, and without a feed no updater is created at all.
@MainActor
@Observable
final class SparkleAppUpdater: NSObject, AppUpdating, SPUUpdaterDelegate {
    private(set) var canCheckForUpdates = false
    let presenter = AppUpdatePresenter()

    var availableVersion: String? {
        if case .found(let version) = presenter.phase { return version }
        return nil
    }

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var feed: URL?

    func start(feedURL: URL?) {
        guard updater == nil, let feedURL else { return }
        feed = feedURL

        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: presenter,
            delegate: self
        )
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        do {
            try updater.start()
        } catch {
            presenter.showUpdaterError(error, acknowledgement: {})
            return
        }
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        self.updater = updater
    }

    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feed?.absoluteString }
    }
}
