import SwiftUI

struct BrowserView: View {
    @Bindable var coordinator: ConnectionCoordinator
    @State private var viewModel = BrowserViewModel()
    @State private var searchInput: String = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var showNewKey = false
    @State private var pendingDeleteKey: Data?
    @State private var deleteError: String?
    @FocusState private var searchFocused: Bool
    @State private var detailEditText: String = ""
    @State private var detailEditInitializedKey: Data?
    @State private var saveError: String?

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
        .onChange(of: viewModel.detailState) { _, newState in
            syncEditText(with: newState)
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
        .background {
            // Hidden focus trigger for Cmd+F
            Button("Focus Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityIdentifier("browser.focusSearchShortcut")
            // Hidden save trigger for Cmd+S when detail is loaded
            Button("Save") { performSave() }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .disabled(!viewModel.canSave || viewModel.isSaving)
                .accessibilityIdentifier("browser.saveShortcut")
        }
    }

    private func syncEditText(with state: BrowserDetailState) {
        guard case .loaded(let key, let value, _) = state else {
            if case .idle = state { detailEditText = "" }
            detailEditInitializedKey = nil
            return
        }
        // Only reset when key changes to preserve in-progress edits
        if detailEditInitializedKey != key {
            if let str = ValuePresentation.textString(from: value) {
                detailEditText = str
            } else {
                detailEditText = ""
            }
            detailEditInitializedKey = key
            saveError = nil
        }
    }

    private func performSave() {
        guard case .loaded(let key, let currentValue, _) = viewModel.detailState else { return }
        guard let client = coordinator.browser else { return }
        guard viewModel.canSave, !viewModel.isSaving else { return }
        let isBinary = !ValuePresentation.isValidUTF8(currentValue)
        if isBinary { return }
        let newData = Data(detailEditText.utf8)
        saveError = nil
        Task {
            await viewModel.save(value: newData, using: client)
            if case .failed(let k, let msg) = viewModel.detailState, k == key {
                saveError = msg
            } else {
                saveError = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Search keys", text: $searchInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($searchFocused)
                .accessibilityIdentifier("browser.searchField")
                .onSubmit {
                    searchTask?.cancel()
                    let text = searchInput
                    guard let client = coordinator.browser else { return }
                    Task { await viewModel.applySearch(text, using: client, count: BrowserViewModel.scanCount) }
                }
            if viewModel.isShowingRefreshOverlay {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("browser.refresh.progress")
            }
            Text("DBSIZE \(viewModel.dbsize)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Button("New Key") { showNewKey = true }
                .disabled(coordinator.browser == nil)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("browser.newKeyButton")
            Button("Refresh") {
                guard let client = coordinator.browser else { return }
                Task { await viewModel.refresh(using: client, count: BrowserViewModel.scanCount) }
            }
            .disabled(!viewModel.canRefresh)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityIdentifier("browser.refreshButton")
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isShowingInitialSkeleton {
            skeletonView
        } else {
            switch viewModel.state {
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
                    emptyView
                } else {
                    browserContent
                }
            }
        }
    }

    private var skeletonView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading keys…")
                    .foregroundStyle(.secondary)
                    .font(.callout.monospaced())
            }
            .padding(12)
            List {
                ForEach(0..<8, id: \.self) { _ in
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text("key_placeholder_xxxxxxxx")
                            .font(.system(.body, design: .monospaced))
                            .redacted(reason: .placeholder)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .disabled(true)
            .redacted(reason: .placeholder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("browser.loading")
    }

    private var emptyView: some View {
        Group {
            if viewModel.isShowingEmptyDatabase {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No keys")
                        .font(.headline)
                    Text("Database is empty.")
                        .foregroundStyle(.secondary)
                        .font(.callout.monospaced())
                    Text("Create your first key to get started.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Button("New Key") { showNewKey = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("browser.empty.newKeyButton")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("browser.empty.db")
            } else if viewModel.isShowingNoResults {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No results")
                        .font(.headline)
                    Text("No results for current search.")
                        .foregroundStyle(.secondary)
                        .font(.callout.monospaced())
                    if !viewModel.searchText.isEmpty {
                        Text("No keys matching \"\(viewModel.searchText)\"")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("browser.empty.searchPattern")
                    }
                    Button("Clear Search") {
                        searchInput = ""
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("browser.empty.clearSearchButton")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("browser.empty.search")
            } else {
                // Fallback empty (covers edge where state not loaded yet)
                VStack(spacing: 8) {
                    Text("No keys")
                        .font(.headline)
                    Text(viewModel.searchText.isEmpty ? "Database is empty." : "No results for current search.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("browser.empty")
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
            if case .loaded(let key, let value, let ttl) = viewModel.detailState {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    // Preserve TTL toggle (charcoal/purple theme, monospace TTL already in detail)
                    if case .expiring = ttl {
                        Toggle(isOn: $viewModel.preserveTTL) {
                            Text("Preserve TTL")
                                .font(.caption.monospaced())
                        }
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("browser.preserveTTLToggle")
                    }
                    // Editable value field – monospace, charcoal
                    if ValuePresentation.isValidUTF8(value) {
                        Text("Edit Value")
                            .font(.caption.weight(.semibold).monospaced())
                            .foregroundStyle(.secondary)
                        TextEditor(text: $detailEditText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 60, maxHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                            .accessibilityIdentifier("browser.editField")
                            .disabled(viewModel.isSaving)
                        if viewModel.isSaving {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Saving…").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            .accessibilityIdentifier("browser.save.progress")
                        }
                        if let err = saveError {
                            Text(err)
                                .font(.caption.monospaced())
                                .foregroundStyle(.red)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .accessibilityIdentifier("browser.save.error")
                        }
                    } else {
                        Text("Binary value — editing as text is disabled. View in Hex.")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("browser.edit.binaryNotice")
                    }
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
                        .disabled(viewModel.isDeleting || viewModel.isSaving)
                        .accessibilityIdentifier("browser.deleteButton")
                        if ValuePresentation.isValidUTF8(value) {
                            Button("Save") { performSave() }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut("s", modifiers: .command)
                                .disabled(!viewModel.canSave || viewModel.isSaving || viewModel.isDeleting)
                                .accessibilityIdentifier("browser.saveButton")
                        }
                    }
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
                        Button("Copy Key") { Pasteboard.copy(key) }
                            .accessibilityIdentifier("browser.row.copyKey")
                        Divider()
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
                .accessibilityHidden(true)
            Text(displayString(for: key))
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityLabels.key(key))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("browser.row.\(displayString(for: key))")
    }

    private func displayString(for data: Data) -> String {
        if let str = String(data: data, encoding: .utf8) {
            return str
        }
        return data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
