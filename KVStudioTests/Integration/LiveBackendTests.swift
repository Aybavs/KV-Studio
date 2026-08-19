import Testing
import Foundation
@testable import KV_Studio

@Suite(
    .timeLimit(.minutes(3)),
    .enabled(if: KVServerBinaryLocator.find() != nil, KVServerBinaryLocator.skipComment)
)
struct LiveBackendTests {

    private var binary: URL { KVServerBinaryLocator.find()! }

    private func client(_ server: KVServerProcess) async throws -> KVClient {
        let connection = KVConnection()
        try await connection.connect(to: server.endpoint)
        return KVClient(connection: connection)
    }

    private func fullScan(_ client: KVClient, match: Data?, count: Int) async throws -> [Data: Int] {
        var cursor: UInt64 = 0
        var seen: [Data: Int] = [:]
        repeat {
            let page = try await client.scan(cursor: cursor, match: match, count: count)
            for key in page.keys { seen[key, default: 0] += 1 }
            cursor = page.nextCursor
        } while cursor != 0
        return seen
    }

    // MARK: - Binary safety

    @Test func binaryKeyAndValueRoundTrip() async throws {
        try await withKVServer(binary: binary) { server in
            let client = try await self.client(server)
            let key = Data([0x00, 0x0D, 0x0A]) + Data("key-".utf8) + Data([0xC3, 0x28, 0xFF, 0xFE])
            let value = Data([0x00, 0x0D, 0x0A]) + Data("value-".utf8) + Data([0xC3, 0x28, 0xFF, 0xFE, 0x80])

            try await client.set(key: key, value: value, expiration: nil)
            #expect(try await client.get(key) == value)
            #expect(try await client.delete([key]) == 1)
        }
    }

    // MARK: - SET/GET/DEL

    @Test func setGetDelRoundTrip() async throws {
        try await withKVServer(binary: binary) { server in
            let client = try await self.client(server)
            let key = Data("sgd:key".utf8)

            #expect(try await client.get(key) == nil)

            try await client.set(key: key, value: Data(), expiration: nil)
            let empty = try await client.get(key)
            #expect(empty == Data())
            #expect(empty != nil)

            try await client.set(key: key, value: Data("value".utf8), expiration: nil)
            #expect(try await client.get(key) == Data("value".utf8))

            let missingKey = Data("sgd:missing".utf8)
            let deleted = try await client.delete([key, missingKey])
            #expect(deleted == 1)
            #expect(try await client.get(key) == nil)
        }
    }

    // MARK: - TTL

    @Test func ttlStatesMatchRealServer() async throws {
        try await withKVServer(binary: binary) { server in
            let client = try await self.client(server)

            #expect(try await client.ttl(Data("ttl:missing".utf8)) == .missing)

            let persistentKey = Data("ttl:persistent".utf8)
            try await client.set(key: persistentKey, value: Data("v".utf8), expiration: nil)
            #expect(try await client.ttl(persistentKey) == .persistent)

            let expiringKey = Data("ttl:expiring".utf8)
            try await client.set(key: expiringKey, value: Data("v".utf8), expiration: .seconds(120))
            guard case .expiring(let seconds) = try await client.ttl(expiringKey) else {
                Issue.record("expected .expiring state")
                return
            }
            #expect(seconds > 0 && seconds <= 120)

            #expect(try await client.persist(expiringKey) == true)
            #expect(try await client.ttl(expiringKey) == .persistent)
        }
    }

    // MARK: - DBSIZE

    @Test func dbSizeReflectsInsertsAndDeletes() async throws {
        try await withKVServer(binary: binary) { server in
            let client = try await self.client(server)
            #expect(try await client.dbSize() == 0)

            let keys = (0..<10).map { Data("dbsize:\($0)".utf8) }
            for key in keys {
                try await client.set(key: key, value: Data("v".utf8), expiration: nil)
            }
            #expect(try await client.dbSize() == keys.count)

            let deletedCount = try await client.delete(Array(keys.prefix(4)))
            #expect(deletedCount == 4)
            #expect(try await client.dbSize() == keys.count - 4)
        }
    }

    // MARK: - SCAN

    @Test func scanRepliesUseNestedRESP2Shape() async throws {
        try await withKVServer(binary: binary) { server in
            let client = try await self.client(server)
            try await client.set(key: Data("shape:1".utf8), value: Data("v".utf8), expiration: nil)

            let reply = try await client.raw([Data("SCAN".utf8), Data("0".utf8), Data("COUNT".utf8), Data("10".utf8)])
            guard case .array(let outer?) = reply, outer.count == 2,
                  case .bulkString(let cursor?) = outer[0],
                  case .array(let inner?) = outer[1] else {
                Issue.record("unexpected SCAN reply shape: \(reply)")
                return
            }
            #expect(!cursor.isEmpty)
            for element in inner {
                guard case .bulkString = element else {
                    Issue.record("expected bulk string key, got \(element)")
                    return
                }
            }
        }
    }

    @Test func scanFullTraversalReturnsEveryKeyExactlyOnce() async throws {
        try await withKVServer(binary: binary) { server in
            let client = try await self.client(server)
            let total = 300
            var expected = Set<Data>()
            for index in 0..<total {
                let key = Data(String(format: "scan:%04d", index).utf8)
                try await client.set(key: key, value: Data("v".utf8), expiration: nil)
                expected.insert(key)
            }

            let seen = try await fullScan(client, match: nil, count: 25)
            #expect(Set(seen.keys) == expected)
            #expect(seen.values.allSatisfy { $0 == 1 })
        }
    }

    @Test func scanMatchFiltersAcrossFullTraversal() async throws {
        try await withKVServer(binary: binary) { server in
            let client = try await self.client(server)
            var matching = Set<Data>()
            for index in 0..<150 {
                let key = Data("match:target:\(index)".utf8)
                try await client.set(key: key, value: Data("v".utf8), expiration: nil)
                matching.insert(key)
            }
            for index in 0..<150 {
                try await client.set(key: Data("other:\(index)".utf8), value: Data("v".utf8), expiration: nil)
            }

            let pattern = Data("match:target:*".utf8)
            let seen = try await fullScan(client, match: pattern, count: 20)
            #expect(Set(seen.keys) == matching)
            #expect(seen.values.allSatisfy { $0 == 1 })
        }
    }

    // MARK: - Concurrency

    @Test func concurrentCallersEachGetTheirOwnCorrectAnswer() async throws {
        try await withKVServer(binary: binary) { server in
            let client = try await self.client(server)
            let count = 50

            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<count {
                    group.addTask {
                        let key = Data("concurrent:\(index)".utf8)
                        let value = Data("value-\(index)".utf8)
                        try await client.set(key: key, value: value, expiration: nil)
                        #expect(try await client.get(key) == value)
                    }
                }
                try await group.waitForAll()
            }

            #expect(try await client.dbSize() == count)
        }
    }
}
