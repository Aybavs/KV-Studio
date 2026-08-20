import SwiftUI

struct LogsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Logs")
                .font(.title2.weight(.semibold))
            Text("Log viewing is not built yet.")
                .foregroundStyle(.secondary)
                .font(.callout.monospaced())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("logs.placeholder")
    }
}
