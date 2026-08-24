import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    let paths: ManagedPaths
    private let store: PreferencesStore
    @ObservationIgnored private let updater: any AppUpdating

    var appearance: Appearance {
        didSet { save() }
    }
    var reopenLastConnection: Bool {
        didSet { save() }
    }
    var autoCheckUpdates: Bool {
        didSet { save() }
    }

    init(paths: ManagedPaths, updater: any AppUpdating = UnavailableAppUpdater()) {
        self.paths = paths
        self.store = PreferencesStore(paths: paths)
        self.updater = updater
        let prefs = store.loadPreferences()
        self.appearance = prefs.appearance
        self.reopenLastConnection = prefs.reopenLastConnection
        self.autoCheckUpdates = prefs.autoCheckUpdates
    }

    var studioVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var bundledVersion: String { BackendPolicy.loadFromBundle().bundledBackend }
    var recommendedVersion: String { BackendPolicy.loadFromBundle().recommendedBackend }
    var minimumVersion: String { BackendPolicy.loadFromBundle().minimumBackend }

    var applicationSupportPath: String { paths.root.path }

    var managedInstalledVersion: String? {
        ServerViewModel.loadBackendVersion(from: paths.backendCurrentMetadata)
    }

    // Reporting "Not installed" for a backend the app will happily launch contradicts itself; the
    // three states are no backend, one whose version was recorded, and one whose version was not.
    var managedInstalledDescription: String {
        Self.installedDescription(
            version: managedInstalledVersion,
            hasBinary: ServerBinaryResolver.isExecutableProgram(at: paths.backendCurrentBinary)
        )
    }

    nonisolated static func installedDescription(version: String?, hasBinary: Bool) -> String {
        if let version { return version }
        return hasBinary ? "Installed, version unrecorded" : "Not installed"
    }

    nonisolated static func shouldRestore(_ prefs: Preferences) -> Bool {
        prefs.reopenLastConnection
    }

    private func save() {
        var prefs = store.loadPreferences()
        prefs.appearance = appearance
        prefs.reopenLastConnection = reopenLastConnection
        prefs.autoCheckUpdates = autoCheckUpdates
        try? store.savePreferences(prefs)
    }
}

extension SettingsViewModel {
    convenience init() {
        let paths = (try? ManagedPaths.resolveDefault()) ?? ManagedPaths(root: URL(filePath: "/tmp/KV Studio"))
        self.init(paths: paths)
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    func checkForUpdates() { updater.checkForUpdates() }

}
