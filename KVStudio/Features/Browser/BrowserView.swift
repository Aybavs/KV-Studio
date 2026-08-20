import SwiftUI

struct BrowserView: View {
    @Bindable var coordinator: ConnectionCoordinator
    @State private var viewModel = BrowserViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: coordinator.browser != nil) {
            guard let client = coordinator.browser else { return }
            if viewModel.state == .idle {
                await viewModel.loadInitial(using: client, count: BrowserViewModel.scanCount)
            }
        }
        .onChange(of: coordinator.phase) { _, newPhase in
            if case .connected = newPhase, let client = coordinator.browser {
                Task { await viewModel.loadInitial(using: client, count: BrowserViewModel.scanCount) }
            }
        }
        .accessibilityIdentifier("browser.view")
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Search keys", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit {
                    guard let client = coordinator.browser else { return }
                    Task { await viewModel.applySearch(viewModel.searchText, using: client, count: BrowserViewModel.scanCount) }
                }
            Text("DBSIZE \(viewModel.dbsize)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Refresh") {
                guard let client = coordinator.browser else { return }
                Task { await viewModel.refresh(using: client, count: BrowserViewModel.scanCount) }
            }
            .disabled(viewModel.state == .initialLoading || viewModel.state == .refreshing)
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .initialLoading, .refreshing where viewModel.keys.isEmpty:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading keys…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("browser.loading")
        case .failed where viewModel.keys.isEmpty:
            VStack(spacing: 12) {
                Text("Failed to load keys")
                    .font(.headline)
                if let msg = viewModel.errorMessage {
                    Text(msg)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Retry") {
                    guard let client = coordinator.browser else { return }
                    Task { await viewModel.loadInitial(using: client, count: BrowserViewModel.scanCount) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("browser.failed")
        default:
            if viewModel.keys.isEmpty {
                VStack(spacing: 8) {
                    Text("No keys")
                        .font(.headline)
                    Text(viewModel.searchText.isEmpty ? "Database is empty." : "No results for current search.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("browser.empty")
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            ForEach(Array(viewModel.keys.enumerated()), id: \.offset) { index, key in
                BrowserKeyRow(key: key, isSelected: viewModel.selection == key)
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.select(key) }
                    .listRowBackground(viewModel.selection == key ? Color.accentColor.opacity(0.12) : Color.clear)
                    .onAppear {
                        guard viewModel.shouldLoadMore(at: index) else { return }
                        guard let client = coordinator.browser else { return }
                        Task { await viewModel.loadMore(using: client, count: BrowserViewModel.scanCount) }
                    }
            }
            if viewModel.state == .loadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .listRowSeparator(.hidden)
            } else if viewModel.endReached {
                HStack {
                    Spacer()
                    Text("End of results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
            if viewModel.state == .failed {
                VStack(spacing: 8) {
                    Text(viewModel.errorMessage ?? "Failed to load more")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        guard let client = coordinator.browser else { return }
                        Task { await viewModel.loadMore(using: client, count: BrowserViewModel.scanCount) }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable {
            guard let client = coordinator.browser else { return }
            await viewModel.refresh(using: client, count: BrowserViewModel.scanCount)
        }
        .accessibilityIdentifier("browser.list")
    }
}

private struct BrowserKeyRow: View {
    let key: Data
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(displayString(for: key))
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption.weight(.bold))
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("browser.row.\(displayString(for: key))")
    }

    private func displayString(for data: Data) -> String {
        if let str = String(data: data, encoding: .utf8) {
            return str
        }
        return data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
