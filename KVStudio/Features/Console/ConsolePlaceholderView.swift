import SwiftUI

struct ConsolePlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Console")
                .font(.title2.weight(.semibold))
            Text("Raw commands are not built yet.")
                .foregroundStyle(.secondary)
                .font(.callout.monospaced())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("console.placeholder")
    }
}
