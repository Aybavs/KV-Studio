import Testing
@testable import KV_Studio

@Suite
struct ConnectionFormValidationTests {

    @Test func emptyHostIsInvalid() {
        let vm = ConnectionOnboardingViewModel(host: "", portText: "6380")
        #expect(vm.hostError != nil)
        #expect(vm.isExistingValid == false)
        #expect(vm.endpoint == nil)
    }

    @Test func whitespaceHostIsInvalid() {
        let vm = ConnectionOnboardingViewModel(host: "   ", portText: "6380")
        #expect(vm.hostError != nil)
    }

    @Test func validHostPasses() {
        let vm = ConnectionOnboardingViewModel(host: "127.0.0.1", portText: "6380")
        #expect(vm.hostError == nil)
    }

    @Test func trimmedHostIsUsedForEndpoint() {
        let vm = ConnectionOnboardingViewModel(host: "  10.0.0.5  ", portText: "6380")
        #expect(vm.endpoint?.host == "10.0.0.5")
    }

    @Test func emptyPortIsInvalid() {
        let vm = ConnectionOnboardingViewModel(host: "127.0.0.1", portText: "")
        #expect(vm.portError != nil)
        #expect(vm.isExistingValid == false)
    }

    @Test func nonNumericPortIsInvalid() {
        let vm = ConnectionOnboardingViewModel(host: "127.0.0.1", portText: "abc")
        #expect(vm.portError != nil)
    }

    @Test func zeroPortIsInvalid() {
        let vm = ConnectionOnboardingViewModel(host: "127.0.0.1", portText: "0")
        #expect(vm.portError != nil)
    }

    @Test func portAboveMaxIsInvalid() {
        let vm = ConnectionOnboardingViewModel(host: "127.0.0.1", portText: "65536")
        #expect(vm.portError != nil)
    }

    @Test func port70000IsInvalid() {
        let vm = ConnectionOnboardingViewModel(host: "127.0.0.1", portText: "70000")
        #expect(vm.portError != nil)
    }

    @Test func negativePortIsInvalid() {
        let vm = ConnectionOnboardingViewModel(host: "127.0.0.1", portText: "-1")
        #expect(vm.portError != nil)
    }

    @Test func validPortsPass() {
        for text in ["1", "6380", "65535"] {
            let vm = ConnectionOnboardingViewModel(host: "127.0.0.1", portText: text)
            #expect(vm.portError == nil, "port \(text) should be valid")
            #expect(vm.isExistingValid == true)
        }
    }

    @Test func portWithWhitespaceIsTrimmedAndValid() {
        let vm = ConnectionOnboardingViewModel(host: "127.0.0.1", portText: " 6380 ")
        #expect(vm.portError == nil)
        #expect(vm.endpoint?.port == 6380)
    }

    @Test func validEndpointIsBuiltFromBothFields() {
        let vm = ConnectionOnboardingViewModel(host: "example.com", portText: "6380")
        #expect(vm.endpoint == ConnectionEndpoint(host: "example.com", port: 6380))
    }

    @Test func invalidHostYieldsNoEndpoint() {
        let vm = ConnectionOnboardingViewModel(host: "", portText: "6380")
        #expect(vm.endpoint == nil)
    }

    @Test func invalidPortYieldsNoEndpoint() {
        let vm = ConnectionOnboardingViewModel(host: "127.0.0.1", portText: "99999")
        #expect(vm.endpoint == nil)
    }

    @Test func parsedPortIsCorrectType() {
        let vm = ConnectionOnboardingViewModel(host: "127.0.0.1", portText: "6380")
        #expect(vm.parsedPort == 6380)
    }
}

@Suite
struct ConnectionOnboardingFailureMessageTests {

    @Test func unreachableOutcomeShowsUnreachable() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let outcome = CompatibilityOutcome.unreachable(.connectFailed("refused"))
        let failure = ConnectionFailure.rejected(endpoint, outcome)
        let message = connectionFailureMessage(for: failure)
        #expect(message.contains("unreachable") || message.contains("Unreachable"))
    }

    @Test func incompatibleOutcomeShowsIncompatible() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let outcome = CompatibilityOutcome.incompatible(step: .dbSize, reason: .serverError(class: .unknownCommand, message: "ERR unknown command 'DBSIZE'"))
        let failure = ConnectionFailure.rejected(endpoint, outcome)
        let message = connectionFailureMessage(for: failure)
        #expect(message.lowercased().contains("incompatible"))
    }

    @Test func protocolFailureShowsProtocol() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let outcome = CompatibilityOutcome.protocolFailure(step: .ping, reason: .connectionClosed)
        let failure = ConnectionFailure.rejected(endpoint, outcome)
        let message = connectionFailureMessage(for: failure)
        #expect(message.lowercased().contains("protocol"))
    }

    @Test func portConflictShowsPortInUse() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let occupancy = PortOccupancy(endpoint: endpoint, occupant: .compatible)
        let failure = ConnectionFailure.portConflict(occupancy)
        let message = connectionFailureMessage(for: failure)
        #expect(message.contains("6380"))
        #expect(message.lowercased().contains("in use"))
    }

    @Test func transportFailureShowsTransportDetail() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let failure = ConnectionFailure.transport(endpoint, .connectFailed("refused"))
        let message = connectionFailureMessage(for: failure)
        #expect(!message.isEmpty)
    }

    @Test func managedServerFailureShowsDetail() {
        let failure = ConnectionFailure.managedServer(.binaryUnavailable(["/nowhere"]))
        let message = connectionFailureMessage(for: failure)
        #expect(!message.isEmpty)
    }

    @Test func interruptedShowsInterrupted() {
        let failure = ConnectionFailure.interrupted
        let message = connectionFailureMessage(for: failure)
        #expect(message.lowercased().contains("interrupt"))
    }

    @Test func onboardingErrorMessageIsNilWhenNotFailed() {
        #expect(onboardingErrorMessage(for: .disconnected) == nil)
        #expect(onboardingErrorMessage(for: .connected(ConnectionSession(target: .managedLocal, endpoint: ConnectionEndpoint(host: "127.0.0.1", port: 6380)))) == nil)
    }

    @Test func onboardingErrorMessageMapsFailedPhase() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let failure = ConnectionAttemptFailure(target: .existing(endpoint), failure: .interrupted)
        let message = onboardingErrorMessage(for: .failed(failure))
        #expect(message != nil)
        #expect(message!.lowercased().contains("interrupt"))
    }
}
