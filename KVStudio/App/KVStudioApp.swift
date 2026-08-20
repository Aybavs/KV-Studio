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
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1_000, height: 640)
    }
}
