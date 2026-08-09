import SwiftUI

/// Stands in for the connection screen until Task 15 builds the real one.
/// It exists so the app has a launchable root while the protocol layer is built.
struct ConnectionPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("KV Studio")
                .font(.largeTitle.weight(.semibold))
            Text("Connection setup is not built yet.")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 640, minHeight: 400)
        .accessibilityIdentifier("connection.placeholder")
    }
}
