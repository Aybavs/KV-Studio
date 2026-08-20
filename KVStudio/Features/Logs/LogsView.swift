import SwiftUI

struct LogsView: View {
    @Bindable var coordinator: ConnectionCoordinator
    @State private var viewModel: LogsViewModel
    @State private var autoscrollState = LogsAutoscrollState(isAutoscrollEnabled: true, isPaused: false)
    @State private var filterText = ""

    init(coordinator: ConnectionCoordinator, store: LogStore = LogStore()) {
        self.coordinator = coordinator
        _viewModel = State(initialValue: LogsViewModel(store: store))
    }

    private var isManaged: Bool {
        LogsAvailability.isManaged(phase: coordinator.phase)
    }

    var body: some View {
        Group {
            if !isManaged {
                VStack(spacing: 12) {
                    Text("Logs unavailable — this server is not managed by KV Studio.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("logs.unavailable")
            } else {
                VStack(spacing: 8) {
                    toolbar
                    logList
                }
                .task {
                    await viewModel.ingest(coordinator.outputLines)
                }
                .onChange(of: viewModel.visibleEntries.count) {
                    guard autoscrollState.shouldAutoscroll else { return }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("logs.view")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField("Search logs", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onChange(of: filterText) { _, new in viewModel.filter = new }
                .accessibilityIdentifier("logs.search")
            Spacer()
            Toggle("Autoscroll", isOn: Binding(
                get: { autoscrollState.isAutoscrollEnabled },
                set: { autoscrollState.isAutoscrollEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .accessibilityIdentifier("logs.autoscroll")
            Button(autoscrollState.isPaused ? "Resume" : "Pause") {
                autoscrollState.isPaused.toggle()
            }
            .accessibilityIdentifier("logs.pause")
            Button("Clear") { viewModel.clear() }
                .accessibilityIdentifier("logs.clear")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List(viewModel.visibleEntries) { line in
                Text(line.text)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .id(line.id)
                    .accessibilityIdentifier("logs.line")
            }
            .listStyle(.plain)
            .onChange(of: viewModel.visibleEntries.count) { _, _ in
                guard autoscrollState.shouldAutoscroll, let last = viewModel.visibleEntries.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
