import Testing
import Foundation
@testable import KV_Studio

@Suite(
    .timeLimit(.minutes(3)),
    .enabled(if: KVServerBinaryLocator.find() != nil, KVServerBinaryLocator.skipComment)
)
struct CompatibilityProbeLiveTests {

    @Test func theRealBackendIsCompatible() async throws {
        let binary = try #require(KVServerBinaryLocator.find())
        try await withKVServer(binary: binary) { server in
            let outcome = try await CompatibilityProbe(budget: .seconds(5)).run(against: server.endpoint)
            #expect(outcome == .compatible)
        }
    }

    @Test func aStoppedBackendIsUnreachable() async throws {
        let binary = try #require(KVServerBinaryLocator.find())
        let endpoint = try await withKVServer(binary: binary) { $0.endpoint }

        let outcome = try await CompatibilityProbe(budget: .seconds(5)).run(against: endpoint)

        guard case .unreachable = outcome else {
            Issue.record("expected an unreachable outcome, got \(outcome)")
            return
        }
    }
}
