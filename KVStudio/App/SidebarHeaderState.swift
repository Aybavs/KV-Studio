import Foundation

struct SidebarHeaderState: Equatable, Sendable {
    let title: String
    let subtitle: String
    let isHealthy: Bool

    init(phase: ConnectionPhase, managedServer: ManagedServerStatus) {
        switch phase {
        case .disconnected:
            switch managedServer {
            case .running:
                self.title = "Local Server"
                self.subtitle = "Running"
                self.isHealthy = true
            case .starting:
                self.title = "Local Server"
                self.subtitle = "Starting…"
                self.isHealthy = false
            case .stopping:
                self.title = "Local Server"
                self.subtitle = "Stopping…"
                self.isHealthy = false
            case .failed:
                self.title = "Local Server"
                self.subtitle = "Failed"
                self.isHealthy = false
            case .unreclaimed:
                self.title = "Local Server"
                self.subtitle = "Running"
                self.isHealthy = false
            case .idle, .stopped:
                self.title = "Disconnected"
                self.subtitle = "Not connected"
                self.isHealthy = false
            }
        case .connecting(let target):
            switch target {
            case .managedLocal:
                self.title = "Connecting…"
                self.subtitle = "Local Server"
            case .existing(let endpoint):
                self.title = "Connecting…"
                self.subtitle = "\(endpoint.host):\(endpoint.port)"
            }
            self.isHealthy = false
        case .connected(let session):
            switch session.target {
            case .managedLocal:
                self.title = "Local Server"
                self.subtitle = "\(session.endpoint.host):\(session.endpoint.port)"
            case .existing(let endpoint):
                self.title = "\(endpoint.host):\(endpoint.port)"
                self.subtitle = "\(session.endpoint.host):\(session.endpoint.port)"
            }
            self.isHealthy = true
        case .failed:
            self.title = "Connection Failed"
            self.subtitle = "Not connected"
            self.isHealthy = false
        }
    }
}
