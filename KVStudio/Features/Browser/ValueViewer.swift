import SwiftUI

struct ValueViewer: View {
    let data: Data
    @State private var selectedMode: ValueFormat = .auto

    private var resolved: ValueFormat {
        ValuePresentation.resolvedFormat(for: data, selected: selectedMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("View", selection: $selectedMode) {
                Text("Auto").tag(ValueFormat.auto)
                Text("Text").tag(ValueFormat.text)
                Text("JSON").tag(ValueFormat.json)
                Text("Hex").tag(ValueFormat.hex)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("valueViewer.modePicker")

            Group {
                switch resolved {
                case .text:
                    textView
                case .json:
                    jsonView
                case .hex:
                    hexView
                case .auto:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: data) { _, _ in
            // Keep user's manual choice; auto resolves automatically
        }
    }

    @ViewBuilder
    private var textView: some View {
        if data.isEmpty {
            Text("(empty)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("valueViewer.text")
        } else if let str = ValuePresentation.textString(from: data) {
            ScrollView {
                Text(str)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("valueViewer.text")
            }
            .frame(maxHeight: 400)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Invalid UTF-8 — \(data.count) bytes cannot be displayed as text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Switch to Hex to inspect raw bytes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(ValuePresentation.hexString(from: data))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("valueViewer.text.invalid")
        }
    }

    @ViewBuilder
    private var jsonView: some View {
        if data.isEmpty {
            Text("(empty)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("valueViewer.json")
        } else if let pretty = ValuePresentation.prettyJSONString(from: data) {
            ScrollView {
                Text(pretty)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("valueViewer.json")
            }
            .frame(maxHeight: 400)
        } else if ValuePresentation.isValidUTF8(data) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Invalid JSON")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let raw = ValuePresentation.textString(from: data) {
                    ScrollView {
                        Text(raw)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
                Text("Switch to Text or Hex to inspect raw bytes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("valueViewer.json.invalid")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Invalid JSON — not valid UTF-8 (\(data.count) bytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Switch to Hex to inspect raw bytes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("valueViewer.json.invalid")
        }
    }

    @ViewBuilder
    private var hexView: some View {
        if data.isEmpty {
            Text("(empty)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("valueViewer.hex")
        } else {
            ScrollView([.horizontal, .vertical]) {
                Text(ValuePresentation.hexDump(from: data, showASCII: true))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("valueViewer.hex")
            }
            .frame(maxHeight: 400)
        }
    }
}
