import Foundation

@MainActor
protocol AppUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

// Stands in when no feed is configured, so the rest of the app can be built and tested without
// Sparkle having anywhere to check.
@MainActor
final class UnavailableAppUpdater: AppUpdating {
    let canCheckForUpdates = false
    func checkForUpdates() {}
}
