import SwiftUI

struct ConsoleView: View {
    @Bindable var coordinator: ConnectionCoordinator
    @State private var viewModel = ConsoleViewModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            responseList
            Divider()
            editorBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("console.view")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Console")
                .font(.headline.monospaced())
            if coordinator.console == nil {
                Text("Not connected — connect to run commands")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("console.notConnectedBanner")
            }
            Spacer()
            Button("Clear") { viewModel.clear() }
                .disabled(!viewModel.canClear)
                .accessibilityIdentifier("console.clearButton")
        }
        .padding(8)
    }

    private var responseList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 6) {
                                Text(">")
                                    .foregroundStyle(.secondary)
                                    .font(.system(.body, design: .monospaced).weight(.bold))
                                Text(entry.command)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("console.entry.command.\(entry.id.uuidString)")
                            }
                            ConsoleResponseContentView(response: entry.response)
                                .padding(.leading, 16)
                                .accessibilityIdentifier("console.entry.response.\(entry.id.uuidString)")
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .id(entry.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: viewModel.entries.count) { _, _ in
                guard let last = viewModel.entries.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .accessibilityIdentifier("console.responseList")
        }
    }

    private var editorBar: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $viewModel.input)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 36, maxHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    .focused($inputFocused)
                    .disabled(viewModel.isRunning)
                    .accessibilityIdentifier("console.input")
                    .onKeyPress(phases: .down) { press in
                        if press.key == KeyEquivalent.return || press.key.character == "\r" {
                            if press.modifiers.contains(.shift) { return .ignored }
                            Task { await viewModel.submit(using: coordinator) }
                            return .handled
                        }
                        if press.key == KeyEquivalent.upArrow {
                            viewModel.historyUp()
                            return .handled
                        }
                        if press.key == KeyEquivalent.downArrow {
                            viewModel.historyDown()
                            return .handled
                        }
                        return .ignored
                    }

                if viewModel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("console.running")
                }

                Button("Run") {
                    Task { await viewModel.submit(using: coordinator) }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(viewModel.isRunning || viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.console == nil)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("console.runButton")

                Button("Shift+Enter newline") {}
                    .hidden()
                    .accessibilityIdentifier("console.shiftEnterHint")
            }
            Text("Enter to run • Shift+Enter for newline • Up/Down for history")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("console.hint")
        }
        .padding(8)
    }
}
