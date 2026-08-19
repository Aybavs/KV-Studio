import Foundation

struct PortOccupancy: Equatable, Sendable {
    let endpoint: ConnectionEndpoint
    let occupant: CompatibilityOutcome?

    var isOccupied: Bool { occupant != nil }
}

struct PortConflictInspector: Sendable {

    private let probe: CompatibilityProbe

    init(budget: Duration = .seconds(5)) {
        probe = CompatibilityProbe(budget: budget)
    }

    func inspect(_ endpoint: ConnectionEndpoint) async throws -> PortOccupancy {
        let outcome = try await probe.run(against: endpoint)
        return PortOccupancy(endpoint: endpoint, occupant: Self.occupant(for: outcome))
    }

    // A refused or invalid connection means nobody holds the port; anything else is an occupant.
    private static func occupant(for outcome: CompatibilityOutcome) -> CompatibilityOutcome? {
        switch outcome {
        case .unreachable(.connectFailed), .unreachable(.invalidPort):
            return nil
        default:
            return outcome
        }
    }
}
