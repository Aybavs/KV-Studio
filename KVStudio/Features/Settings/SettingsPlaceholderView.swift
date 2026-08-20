import SwiftUI

struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Settings")
                .font(.title2.weight(.semibold))
            Text("Settings are not built yet.")
                .foregroundStyle(.secondary)
                .font(.callout.monospaced())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("settings.placeholder")
    }
}
