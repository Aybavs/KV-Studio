import SwiftUI

struct BrowserDetailView: View {
    let state: BrowserDetailState

    var body: some View {
        Group {
            switch state {
            case .idle:
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Select a key")
                        .font(.headline)
                    Text("Choose a key to view its value and TTL.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("browser.detail.idle")
            case .loading(let key):
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading \(displayString(for: key))…")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("browser.detail.loading")
            case .missing(let key):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text("Key no longer exists")
                        .font(.headline)
                    Text(displayString(for: key))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("This key was deleted between SCAN and GET.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("browser.detail.missing")
            case .failed(let key, let message):
                VStack(spacing: 12) {
                    Text("Failed to load key")
                        .font(.headline)
                    Text(displayString(for: key))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("browser.detail.failed")
            case .loaded(let key, let value, let ttl):
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Key")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(displayString(for: key))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .accessibilityIdentifier("browser.detail.key")
                            Text("\(key.count) bytes")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Value")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ValueViewer(data: value)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("browser.detail.value")
                            Text("\(value.count) bytes")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TTL")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(ttlDescription(ttl))
                                .font(.system(.body, design: .monospaced))
                                .accessibilityIdentifier("browser.detail.ttl")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("browser.detail.loaded")
            }
        }
    }

    private func ttlDescription(_ ttl: TTLState) -> String {
        switch ttl {
        case .missing:
            return "Missing"
        case .persistent:
            return "No expiry"
        case .expiring(let seconds):
            return "\(seconds) s remaining"
        }
    }

    private func displayString(for data: Data) -> String {
        if data.isEmpty { return "(empty)" }
        if let str = ValuePresentation.textString(from: data) {
            return str
        }
        return ValuePresentation.hexString(from: data)
    }
}
