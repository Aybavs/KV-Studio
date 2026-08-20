import SwiftUI

struct ConnectionOnboardingView: View {
    @Bindable var coordinator: ConnectionCoordinator
    @Binding var selection: AppRoute?
    @State private var viewModel = ConnectionOnboardingViewModel()

    private var isConnecting: Bool {
        if case .connecting = coordinator.phase { return true }
        return false
    }

    private var errorMessage: String? {
        onboardingErrorMessage(for: coordinator.phase)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                cards
                statusArea
            }
            .padding(32)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("connection.onboarding")
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Welcome to KV Studio")
                .font(.largeTitle.weight(.semibold))
                .accessibilityIdentifier("connection.onboarding.title")
            Text("Connect to a go-kv-store server to get started.")
                .foregroundStyle(.secondary)
        }
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: 20) {
            localCard
            existingCard
        }
    }

    private var localCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Local Server", systemImage: "server.rack")
                .font(.headline)
            Text("Runs a private kv-server managed by Studio on this Mac. Data lives under Application Support and the server starts automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer().frame(height: 4)
            Button {
                Task { await connectLocal() }
            } label: {
                HStack {
                    if isConnecting, case .connecting(.managedLocal) = coordinator.phase {
                        ProgressView().scaleEffect(0.7)
                    }
                    Text("Start Local Server")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting)
            .accessibilityIdentifier("connection.local.start")
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
        .accessibilityIdentifier("connection.card.local")
    }

    private var existingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Existing Server", systemImage: "network")
                .font(.headline)
            Text("Connect to a running go-kv-store at any host and port.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Host", text: $viewModel.host)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("connection.existing.host")
                if let error = viewModel.hostError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("connection.existing.host.error")
                }

                TextField("Port", text: $viewModel.portText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .accessibilityIdentifier("connection.existing.port")
                if let error = viewModel.portError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("connection.existing.port.error")
                }
            }

            Button {
                Task { await connectExisting() }
            } label: {
                HStack {
                    if isConnecting, case .connecting(.existing) = coordinator.phase {
                        ProgressView().scaleEffect(0.7)
                    }
                    Text("Connect")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.isExistingValid || isConnecting)
            .accessibilityIdentifier("connection.existing.connect")
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
        .accessibilityIdentifier("connection.card.existing")
    }

    private var statusArea: some View {
        VStack(spacing: 8) {
            if isConnecting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(connectingLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("connection.status.connecting")
            }
            if let message = errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connection.error")
            }
        }
        .frame(minHeight: 24)
    }

    private var connectingLabel: String {
        switch coordinator.phase {
        case .connecting(.managedLocal): return "Starting local server…"
        case .connecting(.existing(let endpoint)): return "Connecting to \(endpoint.host):\(endpoint.port)…"
        default: return "Connecting…"
        }
    }

    private func connectLocal() async {
        await coordinator.connect(to: .managedLocal)
        if case .connected = coordinator.phase {
            selection = .browser
        }
    }

    private func connectExisting() async {
        guard let endpoint = viewModel.endpoint else { return }
        await coordinator.connect(to: .existing(endpoint))
        if case .connected = coordinator.phase {
            selection = .browser
        }
    }
}
