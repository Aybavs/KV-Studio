import SwiftUI

struct AppShellView: View {
    @Bindable var coordinator: ConnectionCoordinator
    @State private var selection: AppRoute? = .browser

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detailContent
                .toolbar { toolbarContent }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, minHeight: 500)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            SidebarHeaderView(state: SidebarHeaderState(
                phase: coordinator.phase,
                managedServer: coordinator.managedServer
            ))
            .listRowSeparator(.hidden)

            Section("BROWSE") {
                ForEach(AppRoute.routes(in: .browse), id: \.self) { route in
                    Label(route.title, systemImage: route.systemImage)
                        .tag(route)
                }
            }

            Section("MANAGE") {
                ForEach(AppRoute.routes(in: .manage), id: \.self) { route in
                    Label(route.title, systemImage: route.systemImage)
                        .tag(route)
                }
            }

            Section {
                Label(AppRoute.settings.title, systemImage: AppRoute.settings.systemImage)
                    .tag(AppRoute.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("KV Studio")
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .browser:
            BrowserPlaceholderView()
        case .console:
            ConsolePlaceholderView()
        case .server:
            ServerPlaceholderView()
        case .logs:
            LogsPlaceholderView()
        case .settings:
            SettingsPlaceholderView()
        case .none:
            BrowserPlaceholderView()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .status) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isHealthy ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(currentToolbarTitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("toolbar.status")
        }
    }

    private var isHealthy: Bool {
        if case .connected = coordinator.phase { return true }
        return false
    }

    private var currentToolbarTitle: String {
        toolbarTitle(for: coordinator.phase)
    }
}
