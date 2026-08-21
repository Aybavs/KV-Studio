import SwiftUI

struct ServerView: View {
    @Bindable var coordinator: ConnectionCoordinator
    @State private var viewModel: ServerViewModel

    init(coordinator: ConnectionCoordinator) {
        self.coordinator = coordinator
        _viewModel = State(initialValue: ServerViewModel(coordinator: coordinator))
    }

    init(coordinator: ConnectionCoordinator, paths: ManagedPaths) {
        self.coordinator = coordinator
        _viewModel = State(initialValue: ServerViewModel(paths: paths, coordinator: coordinator))
    }

    var body: some View {
        Group {
            if viewModel.isManaged {
                managedView
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("server.managedView")
            } else {
                existingView
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("server.existingView")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { viewModel.refresh() }
        .onChange(of: coordinator.phase) { _, _ in viewModel.refresh() }
        .onChange(of: coordinator.managedServer) { _, _ in viewModel.refresh() }
    }

    // MARK: - Managed

    private var managedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(title: "Server", subtitle: "Managed local server")
                statusCard
                pathsCard
                controlsCard
            }
            .padding(24)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("server.view")
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status")
                .font(.headline)
            Divider()
            row(label: "State", value: viewModel.stateText, identifier: "server.state")
            row(label: "PID", value: viewModel.pidText, identifier: "server.pid")
            row(label: "Host / Port", value: viewModel.hostPortText, identifier: "server.endpoint", mono: true)
            row(label: "Backend Version", value: viewModel.backendVersionText, identifier: "server.backendVersion", mono: true)
            row(label: "Persistence", value: viewModel.aofModeText, identifier: "server.aofMode")
            row(label: "AOF Size", value: viewModel.aofSizeText, identifier: "server.aofSize", mono: true)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("server.statusCard")
    }

    private var pathsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paths")
                .font(.headline)
            Divider()
            pathRow(label: "Binary", value: viewModel.binaryPathText, identifier: "server.binaryPath", action: { viewModel.revealBinaryInFinder() })
            pathRow(label: "Data Directory", value: viewModel.dataPathText, identifier: "server.dataPath", action: { viewModel.revealDataInFinder() })
            pathRow(label: "AOF File", value: viewModel.aofPathText, identifier: "server.aofPath", action: { viewModel.revealAOFInFinder() })
            Button("Reveal Data in Finder") { viewModel.revealDataInFinder() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("server.revealButton")
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("server.pathsCard")
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controls")
                .font(.headline)
            Divider()
            HStack(spacing: 12) {
                Button("Start") { Task { await viewModel.start() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canStart)
                    .accessibilityIdentifier("server.startButton")
                Button("Stop") { Task { await viewModel.stop() } }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!viewModel.canStop)
                    .accessibilityIdentifier("server.stopButton")
                Button("Restart") { Task { await viewModel.restart() } }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canRestart)
                    .accessibilityIdentifier("server.restartButton")
                Spacer()
                Button("Refresh") { viewModel.refresh() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("server.refreshButton")
            }
            if case .failed(let error) = coordinator.managedServer {
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("server.error")
            } else if case .failed(let attempt) = coordinator.phase, case .managedServer(let error) = attempt.failure {
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("server.error")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("server.controlsCard")
    }

    // MARK: - Existing

    private var existingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(title: "Server", subtitle: "External server — not managed by Studio")
                VStack(alignment: .leading, spacing: 12) {
                    Label("External Connection", systemImage: "network")
                        .font(.headline)
                        .accessibilityIdentifier("server.externalBadge")
                    Divider()
                    row(label: "Endpoint", value: viewModel.hostPortText, identifier: "server.endpoint", mono: true)
                    row(label: "Compatibility", value: viewModel.compatibilityText, identifier: "server.compatibility")
                    Text("Process controls and managed data are hidden for external servers.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("server.existingNote")
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("server.existingCard")
            }
            .padding(24)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("server.view")
    }

    // MARK: - Helpers

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("server.title")
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("server.subtitle")
        }
    }

    private func row(label: String, value: String, identifier: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(mono ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(identifier)
    }

    private func pathRow(label: String, value: String, identifier: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)
            Button("Reveal") { action() }
                .buttonStyle(.link)
                .font(.callout)
                .accessibilityIdentifier(identifier + ".reveal")
        }
    }
}
