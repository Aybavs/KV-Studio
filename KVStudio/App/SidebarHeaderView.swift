import SwiftUI

struct SidebarHeaderView: View {
    let state: SidebarHeaderState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("KV Studio")
                .font(.headline)
            HStack(spacing: 6) {
                Circle()
                    .fill(state.isHealthy ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(state.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            Text(state.subtitle)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("app.title")
        .accessibilityLabel("KV Studio")
        .accessibilityValue("\(state.title), \(state.subtitle)")
    }
}
