import SwiftUI

struct ServerPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Server")
                .font(.title2.weight(.semibold))
            Text("Server controls are not built yet.")
                .foregroundStyle(.secondary)
                .font(.callout.monospaced())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("server.placeholder")
    }
}
