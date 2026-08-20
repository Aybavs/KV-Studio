import AppKit
import SwiftUI

@main
struct KVStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator: ConnectionCoordinator
    @State private var settings: SettingsViewModel
    @State private var updater: SparkleAppUpdater

    init() {
        let paths: ManagedPaths
        do {
            paths = try ManagedPaths.resolveDefault()
        } catch {
            fatalError("KV Studio requires Application Support directory: \(error)")
        }
        _coordinator = State(initialValue: ConnectionCoordinator(paths: paths))
        let updater = SparkleAppUpdater()
        _updater = State(initialValue: updater)
        _settings = State(initialValue: SettingsViewModel(paths: paths, updater: updater))
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
                    let prefs = PreferencesStore(paths: coordinator.paths).loadPreferences()
                    guard SettingsViewModel.shouldRestore(prefs) else { return }
                    await coordinator.restoreLastConnection()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1_000, height: 640)
    }
}
