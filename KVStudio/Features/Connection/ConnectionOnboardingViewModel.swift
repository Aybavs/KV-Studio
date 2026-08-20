import Foundation
import Observation

@Observable
final class ConnectionOnboardingViewModel {
    var host: String
    var portText: String

    init(host: String = "127.0.0.1", portText: String = "6380") {
        self.host = host
        self.portText = portText
    }

    var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedPortText: String {
        portText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hostError: String? {
        trimmedHost.isEmpty ? "Host is required" : nil
    }

    var parsedPort: UInt16? {
        guard !trimmedPortText.isEmpty else { return nil }
        guard let value = UInt32(trimmedPortText), (1...65535).contains(Int(value)) else { return nil }
        return UInt16(value)
    }

    var portError: String? {
        if trimmedPortText.isEmpty { return "Port is required" }
        if parsedPort == nil { return "Port must be between 1 and 65535" }
        return nil
    }

    var isExistingValid: Bool {
        hostError == nil && portError == nil
    }

    var endpoint: ConnectionEndpoint? {
        guard let port = parsedPort, hostError == nil else { return nil }
        return ConnectionEndpoint(host: trimmedHost, port: port)
    }
}

func connectionFailureMessage(for failure: ConnectionFailure) -> String {
    switch failure {
    case .rejected(_, let outcome):
        switch outcome {
        case .compatible:
            return "Incompatible server"
        case .unreachable:
            return "Server unreachable"
        case .incompatible:
            return "Incompatible server"
        case .protocolFailure:
            return "Protocol error"
        }
    case .portConflict(let occupancy):
        return "Port \(occupancy.endpoint.port) in use"
    case .managedServer(let error):
        return error.localizedDescription
    case .transport(_, let error):
        return error.localizedDescription
    case .interrupted:
        return "Connection interrupted"
    }
}

func onboardingErrorMessage(for phase: ConnectionPhase) -> String? {
    guard case .failed(let attempt) = phase else { return nil }
    return connectionFailureMessage(for: attempt.failure)
}
