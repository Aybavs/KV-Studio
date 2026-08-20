import Foundation
import Testing
@testable import KV_Studio

@MainActor
private final class StubUpdater: AppUpdating {
    var canCheckForUpdates: Bool
    var availableVersion: String?
    private(set) var checks = 0

    init(canCheckForUpdates: Bool) { self.canCheckForUpdates = canCheckForUpdates }

    func checkForUpdates() { checks += 1 }
}

@MainActor
@Suite
struct AppUpdatingTests {

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-updates-\(UUID().uuidString)", isDirectory: true)
        let paths = ManagedPaths(root: root)
        try paths.createDirectoryTree()
        return paths
    }

    @Test func withoutAFeedTheAppCannotCheckAndDoesNothing() {
        let updater = UnavailableAppUpdater()
        #expect(updater.canCheckForUpdates == false)
        updater.checkForUpdates()
    }

    @Test func settingsDefaultsToAnUpdaterThatCannotCheck() throws {
        let model = SettingsViewModel(paths: try makePaths())
        defer { try? FileManager.default.removeItem(at: model.paths.root) }
        #expect(model.canCheckForUpdates == false)
    }

    @Test func settingsForwardsTheCheckToTheUpdater() throws {
        let updater = StubUpdater(canCheckForUpdates: true)
        let model = SettingsViewModel(paths: try makePaths(), updater: updater)
        defer { try? FileManager.default.removeItem(at: model.paths.root) }

        #expect(model.canCheckForUpdates)
        model.checkForUpdates()
        model.checkForUpdates()

        #expect(updater.checks == 2)
    }

    @Test func settingsReportsWhenTheUpdaterIsNotReadyYet() throws {
        let updater = StubUpdater(canCheckForUpdates: false)
        let model = SettingsViewModel(paths: try makePaths(), updater: updater)
        defer { try? FileManager.default.removeItem(at: model.paths.root) }
        #expect(model.canCheckForUpdates == false)
    }
}

@MainActor
@Suite
struct SparkleAppUpdaterTests {

    // No feed means no updater is started at all, which is what keeps the suite from reaching the
    // network and what makes "no silent installation" true by construction before a feed exists.
    @Test func staysInertUntilAFeedIsConfigured() {
        let updater = SparkleAppUpdater()
        updater.start(feedURL: nil)
        #expect(updater.canCheckForUpdates == false)
        updater.checkForUpdates()
    }
}
