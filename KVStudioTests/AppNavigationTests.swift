import Testing
@testable import KV_Studio

@Suite
struct AppRouteTests {

    @Test func allRoutesArePresentInSidebarOrder() {
        let routes = AppRoute.allCases
        #expect(routes == [.browser, .console, .server, .logs, .settings])
    }

    @Test func routeGroupsMatchSpec() {
        #expect(AppRoute.browser.group == .browse)
        #expect(AppRoute.console.group == .browse)
        #expect(AppRoute.server.group == .manage)
        #expect(AppRoute.logs.group == .manage)
        #expect(AppRoute.settings.group == .settings)
    }

    @Test func routeTitlesAreHumanReadable() {
        #expect(AppRoute.browser.title == "Browser")
        #expect(AppRoute.console.title == "Console")
        #expect(AppRoute.server.title == "Server")
        #expect(AppRoute.logs.title == "Logs")
        #expect(AppRoute.settings.title == "Settings")
    }

    @Test func sidebarGroupOrderIsBrowseManageSettings() {
        let groups = AppRoute.sidebarGroups
        #expect(groups == [.browse, .manage, .settings])
    }
}

@Suite
struct SidebarHeaderStateTests {

    @Test func disconnectedShowsDisconnected() {
        let state = SidebarHeaderState(phase: .disconnected, managedServer: .idle)
        #expect(state.title == "Disconnected")
        #expect(state.isHealthy == false)
    }

    @Test func connectingLocalShowsConnecting() {
        let state = SidebarHeaderState(phase: .connecting(.managedLocal), managedServer: .starting)
        #expect(state.title == "Connecting…")
        #expect(state.subtitle == "Local Server")
        #expect(state.isHealthy == false)
    }

    @Test func connectedLocalShowsLocalServerAndEndpoint() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let session = ConnectionSession(target: .managedLocal, endpoint: endpoint)
        let state = SidebarHeaderState(phase: .connected(session), managedServer: .running(1234))
        #expect(state.title == "Local Server")
        #expect(state.subtitle == "127.0.0.1:6380")
        #expect(state.isHealthy == true)
    }

    @Test func connectedExistingShowsEndpoint() {
        let endpoint = ConnectionEndpoint(host: "10.0.0.5", port: 6380)
        let session = ConnectionSession(target: .existing(endpoint), endpoint: endpoint)
        let state = SidebarHeaderState(phase: .connected(session), managedServer: .idle)
        #expect(state.subtitle == "10.0.0.5:6380")
        #expect(state.isHealthy == true)
    }

    @Test func failedShowsFailedTitle() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let failure = ConnectionAttemptFailure(target: .existing(endpoint), failure: .interrupted)
        let state = SidebarHeaderState(phase: .failed(failure), managedServer: .idle)
        #expect(state.title == "Connection Failed")
        #expect(state.isHealthy == false)
    }

    @Test func disconnectedWithRunningServerShowsLocalServer() {
        let state = SidebarHeaderState(phase: .disconnected, managedServer: .running(1234))
        #expect(state.title == "Local Server")
        #expect(state.subtitle == "Running")
        #expect(state.isHealthy == true)
    }
}

@Suite
struct ToolbarTitleTests {

    @Test func rejectedUnreachableShowsHumanPhrase() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let outcome = CompatibilityOutcome.unreachable(.connectFailed("refused"))
        let failure = ConnectionAttemptFailure(target: .existing(endpoint), failure: .rejected(endpoint, outcome))
        let title = toolbarTitle(for: .failed(failure))
        #expect(title == "Server unreachable")
        #expect(!title.contains("incompatible"))
        #expect(!title.contains("Compatible"))
        #expect(!title.contains("("))
    }

    @Test func rejectedIncompatibleShowsIncompatiblePhrase() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let outcome = CompatibilityOutcome.incompatible(step: .dbSize, reason: .serverError(class: .unknownCommand, message: "ERR unknown command 'DBSIZE'"))
        let failure = ConnectionAttemptFailure(target: .existing(endpoint), failure: .rejected(endpoint, outcome))
        let title = toolbarTitle(for: .failed(failure))
        #expect(title == "Incompatible server")
        #expect(!title.contains("incompatible(step:"))
        #expect(!title.contains("("))
    }

    @Test func rejectedProtocolFailureShowsProtocolPhrase() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let outcome = CompatibilityOutcome.protocolFailure(step: .ping, reason: .connectionClosed)
        let failure = ConnectionAttemptFailure(target: .existing(endpoint), failure: .rejected(endpoint, outcome))
        let title = toolbarTitle(for: .failed(failure))
        #expect(title == "Protocol error")
        #expect(!title.contains("protocolFailure"))
    }

    @Test func portConflictShowsPortInUse() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let occupancy = PortOccupancy(endpoint: endpoint, occupant: .incompatible(step: .dbSize, reason: .serverError(class: .unknownCommand, message: "ERR unknown")))
        let failure = ConnectionAttemptFailure(target: .managedLocal, failure: .portConflict(occupancy))
        let title = toolbarTitle(for: .failed(failure))
        #expect(title == "Port 6380 in use")
    }

    @Test func interruptedShowsInterruptedPhrase() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let failure = ConnectionAttemptFailure(target: .existing(endpoint), failure: .interrupted)
        let title = toolbarTitle(for: .failed(failure))
        #expect(title == "Connection interrupted")
        #expect(!title.contains("("))
    }
}
