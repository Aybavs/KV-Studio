import Testing
import Foundation
@testable import KV_Studio

@Suite(.timeLimit(.minutes(1)))
struct PortConflictInspectorTests {

    private let inspector = PortConflictInspector(budget: .seconds(5))

    @Test func freePortIsNotOccupied() async throws {
        let port = try KVServerProcess.allocatePort()

        let occupancy = try await inspector.inspect(ConnectionEndpoint(host: "127.0.0.1", port: port))

        #expect(occupancy.isOccupied == false)
        #expect(occupancy.occupant == nil)
    }

    @Test func invalidPortIsNotOccupied() async throws {
        let occupancy = try await inspector.inspect(ConnectionEndpoint(host: "127.0.0.1", port: 0))

        #expect(occupancy.isOccupied == false)
        #expect(occupancy.occupant == nil)
    }

    @Test func healthyServerIsOccupiedByACompatibleServer() async throws {
        let server = try FakeServer { peer in
            for reply in ["+PONG\r\n", ":3\r\n", "*2\r\n$1\r\n0\r\n*0\r\n"] {
                guard peer.readCommand() != nil else { return }
                peer.write(Data(reply.utf8))
            }
        }
        defer { server.stop() }

        let occupancy = try await inspector.inspect(server.endpoint)

        #expect(occupancy.isOccupied)
        #expect(occupancy.occupant == .compatible)
    }

    @Test func incompatibleServerIsOccupiedButNotCompatible() async throws {
        let server = try FakeServer { peer in
            guard peer.readCommand() != nil else { return }
            peer.write(Data("+PONG\r\n".utf8))
            guard peer.readCommand() != nil else { return }
            peer.write(Data("-ERR unknown command 'DBSIZE'\r\n".utf8))
        }
        defer { server.stop() }

        let occupancy = try await inspector.inspect(server.endpoint)

        #expect(occupancy.isOccupied)
        #expect(occupancy.occupant == .incompatible(
            step: .dbSize,
            reason: .serverError(class: .unknownCommand, message: "ERR unknown command 'DBSIZE'")
        ))
    }

    @Test func silentPeerIsOccupiedButBoundedNotAHang() async throws {
        let holder = try PortHolder()
        defer { holder.close() }
        let budget = Duration.milliseconds(300)
        let inspector = PortConflictInspector(budget: budget)

        let started = ContinuousClock.now
        let occupancy = try await inspector.inspect(holder.endpoint)
        let elapsed = ContinuousClock.now - started

        #expect(occupancy.isOccupied)
        // The step the budget expires on tracks connect speed, so only the timeout itself is pinned.
        guard case .unreachable(.timedOut(_, let reported)) = occupancy.occupant else {
            Issue.record("expected a bounded timeout, got \(String(describing: occupancy.occupant))")
            return
        }
        #expect(reported == budget)
        #expect(elapsed >= budget)
        #expect(elapsed < .seconds(5))
        #expect(holder.acceptedPeerHungUp(within: .seconds(2)))
    }
}
