import SwiftUI

@main
struct KVStudioApp: App {
    var body: some Scene {
        WindowGroup {
            ConnectionPlaceholderView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1_000, height: 640)
    }
}
