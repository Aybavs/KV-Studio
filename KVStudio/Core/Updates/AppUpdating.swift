import Foundation

@MainActor
protocol AppUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    var availableVersion: String? { get }
    func checkForUpdates()
}

// Stands in when no feed is configured, so the rest of the app can be built and tested without
// Sparkle having anywhere to check.
@MainActor
final class UnavailableAppUpdater: AppUpdating {
    let canCheckForUpdates = false
    let availableVersion: String? = nil
    func checkForUpdates() {}
}
