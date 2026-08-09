import SwiftUI

/// Temporary root until the real connection screen exists.
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
