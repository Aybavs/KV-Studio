import AppKit
import SwiftUI

@main
struct KVStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator: ConnectionCoordinator
    @State private var settings: SettingsViewModel
    @State private var updater: SparkleAppUpdater
    @State private var updates: UpdateCoordinator
    @State private var storageFailure: UserFacingError?

    init() {
        let resolved = Result { try ManagedPaths.resolveDefault() }
        // Falling back silently would put the user's data somewhere purgeable, so the app instead
        // opens on an explanation it can actually read.
        let paths = (try? resolved.get())
            ?? ManagedPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("KV Studio", isDirectory: true))
        _storageFailure = State(initialValue: resolved.failureError.map(UserFacingError.describing))
        // One host for the whole app: the connection coordinator and the activator must never
        // drive two different managed servers.
        let host = ManagedServerHost(paths: paths)
        _coordinator = State(initialValue: ConnectionCoordinator(paths: paths, server: host))
        let updater = SparkleAppUpdater()
        _updater = State(initialValue: updater)
        _settings = State(initialValue: SettingsViewModel(paths: paths, updater: updater))
        _updates = State(initialValue: UpdateCoordinator(
            paths: paths,
            releases: BackendReleaseLookup(),
            stager: BackendStager(paths: paths),
            activator: BackendActivator(paths: paths, host: host),
            appUpdater: updater
        ))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let storageFailure {
                    UnavailableStorageView(error: storageFailure)
                } else {
                    AppShellView(coordinator: coordinator, settings: settings)
                }
            }
                .preferredColorScheme(settings.appearance.colorScheme)
                .sheet(isPresented: Binding(
                    get: { updater.presenter.phase.isPresentable },
                    // Esc and the window's own dismissal must answer Sparkle, not just hide the sheet.
                    set: { if !$0 { updater.presenter.dismiss() } }
                )) {
                    AppUpdateSheet(presenter: updater.presenter)
                }
                .task {
                    appDelegate.shutDown = { await coordinator.shutDown() }
                    // A backend the previous Studio staged is activated before anything connects.
                    await updates.activateStagedBackendIfPresent()
                    let prefs = PreferencesStore(paths: coordinator.paths).loadPreferences()
                    if prefs.autoCheckUpdates { await updates.check() }
                    guard SettingsViewModel.shouldRestore(prefs) else { return }
                    await coordinator.restoreLastConnection()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1_000, height: 640)
    }
}
