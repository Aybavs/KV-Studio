import AppKit
import SwiftUI

@main
struct KVStudioApp: App {
    @State private var coordinator: ConnectionCoordinator

    init() {
        let paths: ManagedPaths
        do {
            paths = try ManagedPaths.resolveDefault()
        } catch {
            fatalError("KV Studio requires Application Support directory: \(error)")
        }
        _coordinator = State(initialValue: ConnectionCoordinator(paths: paths))
    }

    var body: some Scene {
        WindowGroup {
            AppShellView(coordinator: coordinator)
                .task {
                    await coordinator.restoreLastConnection()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    Task { await coordinator.shutDown() }
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1_000, height: 640)
    }
}
