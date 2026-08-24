import Foundation

enum KVClientError: Error, Equatable, Sendable {
    case serverError(Data)
    case unexpectedReply(RESPValue)
}

actor KVClient {
    private let connection: KVConnection

    private enum Command {
        static let ping = Data("PING".utf8)
        static let version = Data("VERSION".utf8)
        static let dbsize = Data("DBSIZE".utf8)
        static let scan = Data("SCAN".utf8)
        static let match = Data("MATCH".utf8)
        static let count = Data("COUNT".utf8)
        static let get = Data("GET".utf8)
        static let set = Data("SET".utf8)
        static let ex = Data("EX".utf8)
        static let px = Data("PX".utf8)
        static let del = Data("DEL".utf8)
        static let ttl = Data("TTL".utf8)
        static let persist = Data("PERSIST".utf8)
    }

    init(connection: KVConnection) {
        self.connection = connection
    }

    func ping() async throws {
        let reply = try await execute([Command.ping])
        guard case .simpleString = reply else { throw KVClientError.unexpectedReply(reply) }
    }

    /// A server older than go-kv-store 1.2 answers `ERR unknown command`, which is itself an
    /// answer: the version cannot be asked for, rather than the call having failed.
    func serverVersion() async throws -> String? {
        let reply = try await connection.send([Command.version])
        switch reply {
        case .bulkString(let data?): return String(decoding: data, as: UTF8.self)
        case .error: return nil
        default: throw KVClientError.unexpectedReply(reply)
        }
    }

    func dbSize() async throws -> Int {
        let reply = try await execute([Command.dbsize])
        guard case .integer(let count) = reply else { throw KVClientError.unexpectedReply(reply) }
        return Int(count)
    }

    func scan(cursor: UInt64, match: Data?, count: Int) async throws -> ScanPage {
        var arguments = [Command.scan, Data(String(cursor).utf8)]
        if let match {
            arguments.append(Command.match)
            arguments.append(match)
        }
        arguments.append(Command.count)
        arguments.append(Data(String(count).utf8))

        let reply = try await execute(arguments)
        guard case .array(let elements?) = reply, elements.count == 2,
              case .bulkString(let cursorBytes?) = elements[0],
              case .array(let keyElements?) = elements[1],
              let nextCursor = Self.parseCursor(cursorBytes) else {
            throw KVClientError.unexpectedReply(reply)
        }

        var keys: [Data] = []
        keys.reserveCapacity(keyElements.count)
        for element in keyElements {
            guard case .bulkString(let key?) = element else {
                throw KVClientError.unexpectedReply(reply)
            }
            keys.append(key)
        }
        return ScanPage(nextCursor: nextCursor, keys: keys)
    }

    func get(_ key: Data) async throws -> Data? {
        let reply = try await execute([Command.get, key])
        guard case .bulkString(let value) = reply else { throw KVClientError.unexpectedReply(reply) }
        return value
    }

    func set(key: Data, value: Data, expiration: SetExpiration?) async throws {
        var arguments = [Command.set, key, value]
        switch expiration {
        case .seconds(let seconds):
            arguments.append(Command.ex)
            arguments.append(Data(String(seconds).utf8))
        case .milliseconds(let milliseconds):
            arguments.append(Command.px)
            arguments.append(Data(String(milliseconds).utf8))
        case nil:
            break
        }

        let reply = try await execute(arguments)
        guard case .simpleString = reply else { throw KVClientError.unexpectedReply(reply) }
    }

    func delete(_ keys: [Data]) async throws -> Int {
        let reply = try await execute([Command.del] + keys)
        guard case .integer(let count) = reply else { throw KVClientError.unexpectedReply(reply) }
        return Int(count)
    }

    func ttl(_ key: Data) async throws -> TTLState {
        let reply = try await execute([Command.ttl, key])
        guard case .integer(let seconds) = reply else { throw KVClientError.unexpectedReply(reply) }
        switch seconds {
        case -2: return .missing
        case -1: return .persistent
        default: return .expiring(seconds: seconds)
        }
    }

    func persist(_ key: Data) async throws -> Bool {
        let reply = try await execute([Command.persist, key])
        guard case .integer(let count) = reply else { throw KVClientError.unexpectedReply(reply) }
        switch count {
        case 1: return true
        case 0: return false
        default: throw KVClientError.unexpectedReply(reply)
        }
    }

    func raw(_ arguments: [Data]) async throws -> RESPValue {
        try await connection.send(arguments)
    }

    private func execute(_ arguments: [Data]) async throws -> RESPValue {
        let reply = try await connection.send(arguments)
        if case .error(let message) = reply {
            throw KVClientError.serverError(message)
        }
        return reply
    }

    private static func parseCursor(_ data: Data) -> UInt64? {
        guard !data.isEmpty else { return nil }
        var value: UInt64 = 0
        for byte in data {
            guard (0x30...0x39).contains(byte) else { return nil }
            let (scaled, scaleOverflowed) = value.multipliedReportingOverflow(by: 10)
            guard !scaleOverflowed else { return nil }
            let (next, addOverflowed) = scaled.addingReportingOverflow(UInt64(byte - 0x30))
            guard !addOverflowed else { return nil }
            value = next
        }
        return value
    }
}
