import SwiftUI

struct BrowserPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Browser")
                .font(.title2.weight(.semibold))
            Text("Key browsing is not built yet.")
                .foregroundStyle(.secondary)
                .font(.callout.monospaced())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("browser.placeholder")
    }
}
