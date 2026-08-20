import AppKit
import SwiftUI

@main
struct KVStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator: ConnectionCoordinator
    @State private var settings: SettingsViewModel
    @State private var updater: SparkleAppUpdater
    @State private var updates: UpdateCoordinator

    init() {
        let paths: ManagedPaths
        do {
            paths = try ManagedPaths.resolveDefault()
        } catch {
            fatalError("KV Studio requires Application Support directory: \(error)")
        }
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
            AppShellView(coordinator: coordinator, settings: settings)
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
