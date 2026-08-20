import Foundation

struct UpdatePlan: Equatable, Sendable {
    let studioVersion: String?
    let installedBackend: SemanticVersion?
    let availableBackend: SemanticVersion?

    var hasStudioUpdate: Bool { studioVersion != nil }

    var hasBackendUpdate: Bool {
        guard let availableBackend else { return false }
        guard let installedBackend else { return true }
        return availableBackend > installedBackend
    }

    var hasAnything: Bool { hasStudioUpdate || hasBackendUpdate }
}

enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case updateAvailable(UpdatePlan)
    case downloadingBackend
    case stagingBackend
    case stagingApp
    case stoppingServer
    case relaunchRequired
    case activatingBackend
    case verifying
    case completed
    case rolledBack(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloadingBackend, .stagingBackend, .stagingApp,
             .stoppingServer, .activatingBackend, .verifying:
            return true
        case .idle, .updateAvailable, .relaunchRequired, .completed, .rolledBack, .failed:
            return false
        }
    }
}
