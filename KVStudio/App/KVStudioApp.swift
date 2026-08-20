import AppKit
import SwiftUI

@main
struct KVStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator: ConnectionCoordinator
    @State private var settings: SettingsViewModel

    init() {
        let paths: ManagedPaths
        do {
            paths = try ManagedPaths.resolveDefault()
        } catch {
            fatalError("KV Studio requires Application Support directory: \(error)")
        }
        _coordinator = State(initialValue: ConnectionCoordinator(paths: paths))
        _settings = State(initialValue: SettingsViewModel(paths: paths))
    }

    var body: some Scene {
        WindowGroup {
            AppShellView(coordinator: coordinator, settings: settings)
                .preferredColorScheme(settings.appearance.colorScheme)
                .task {
                    appDelegate.shutDown = { await coordinator.shutDown() }
                    let prefs = PreferencesStore(paths: coordinator.paths).loadPreferences()
                    guard SettingsViewModel.shouldRestore(prefs) else { return }
                    await coordinator.restoreLastConnection()
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1_000, height: 640)
    }
}
