import SwiftUI

struct BrowserView: View {
    @Bindable var coordinator: ConnectionCoordinator
    @State private var viewModel = BrowserViewModel()
    @State private var searchInput: String = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var showNewKey = false
    @State private var pendingDeleteKey: Data?
    @State private var deleteError: String?

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
        .onAppear {
            searchInput = viewModel.searchText
        }
        .onChange(of: viewModel.searchText) { _, newValue in
            if newValue != searchInput {
                searchInput = newValue
            }
        }
        .onChange(of: searchInput) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                do {
                    try await Task.sleep(nanoseconds: GlobPattern.searchDebounceNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let client = coordinator.browser else { return }
                await viewModel.applySearch(newValue, using: client, count: BrowserViewModel.scanCount)
            }
        }
        .onChange(of: coordinator.phase) { _, newPhase in
            if case .connected = newPhase, let client = coordinator.browser {
                Task { await viewModel.loadInitial(using: client, count: BrowserViewModel.scanCount) }
            }
        }
        .onChange(of: viewModel.selection) { _, newKey in
            guard let key = newKey, let client = coordinator.browser else { return }
            Task { await viewModel.loadDetail(for: key, using: client) }
        }
        .sheet(isPresented: $showNewKey) {
            if let client = coordinator.browser {
                NewKeyView(viewModel: viewModel, client: client)
            }
        }
        .alert("Delete key?", isPresented: showDeleteAlert, presenting: pendingDeleteKey) { key in
            Button("Delete", role: .destructive) {
                guard let client = coordinator.browser else { return }
                Task {
                    do {
                        try await viewModel.deleteKey(key, using: client)
                        deleteError = nil
                    } catch {
                        if let kv = error as? KVClientError, case .serverError(let data) = kv {
                            deleteError = String(decoding: data, as: UTF8.self)
                        } else {
                            deleteError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                        }
                    }
                    pendingDeleteKey = nil
                }
            }
            .accessibilityIdentifier("browser.delete.confirm")
            Button("Cancel", role: .cancel) { pendingDeleteKey = nil }
        } message: { key in
            VStack(alignment: .leading, spacing: 6) {
                Text("This action cannot be undone.")
                Text(BrowserViewModel.deletePreview(for: key))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("browser.delete.preview")
            }
        }
        .accessibilityIdentifier("browser.view")
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Search keys", text: $searchInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .accessibilityIdentifier("browser.searchField")
                .onSubmit {
                    searchTask?.cancel()
                    let text = searchInput
                    guard let client = coordinator.browser else { return }
                    Task { await viewModel.applySearch(text, using: client, count: BrowserViewModel.scanCount) }
                }
            Text("DBSIZE \(viewModel.dbsize)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Button("New Key") { showNewKey = true }
                .disabled(coordinator.browser == nil)
                .accessibilityIdentifier("browser.newKeyButton")
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
                browserContent
            }
        }
    }

    private var browserContent: some View {
        HStack(spacing: 0) {
            list
                .frame(minWidth: 220, idealWidth: 320, maxWidth: .infinity)
            Divider()
            detailPane
                .frame(minWidth: 220, idealWidth: 360, maxWidth: .infinity)
        }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            BrowserDetailView(state: viewModel.detailState)
            if case .loaded(let key, _, _) = viewModel.detailState {
                Divider()
                HStack(spacing: 12) {
                    Spacer()
                    if let err = deleteError {
                        Text(err)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("browser.delete.error")
                    }
                    if viewModel.isDeleting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityIdentifier("browser.delete.progress")
                    }
                    Button(role: .destructive) { pendingDeleteKey = key } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(viewModel.isDeleting)
                    .accessibilityIdentifier("browser.deleteButton")
                }
                .padding(8)
            }
        }
    }

    private var showDeleteAlert: Binding<Bool> {
        Binding(get: { pendingDeleteKey != nil }, set: { if !$0 { pendingDeleteKey = nil } })
    }

    private var list: some View {
        List {
            ForEach(Array(viewModel.keys.enumerated()), id: \.offset) { index, key in
                BrowserKeyRow(key: key, isSelected: viewModel.selection == key)
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.select(key) }
                    .listRowBackground(viewModel.selection == key ? Color.accentColor.opacity(0.12) : Color.clear)
                    .contextMenu {
                        Button("Delete", role: .destructive) { pendingDeleteKey = key }
                            .accessibilityIdentifier("browser.row.delete.\(BrowserViewModel.deletePreview(for: key))")
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDeleteKey = key } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
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
