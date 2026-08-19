import Darwin
import Foundation

// Written before the spawn without a pid, then rewritten with one: a crash in between still
// leaves enough on disk to find the orphan.
struct ManagedServerRecord: Codable, Equatable, Sendable {
    let pid: pid_t?
    let host: String
    let port: UInt16
    let binaryPath: String
    let processStartTime: ProcessStartTime?
    let startedAt: Date

    static func intent(endpoint: ConnectionEndpoint, binaryPath: String, startedAt: Date) -> ManagedServerRecord {
        ManagedServerRecord(
            pid: nil,
            host: endpoint.host,
            port: endpoint.port,
            binaryPath: binaryPath,
            processStartTime: nil,
            startedAt: startedAt
        )
    }

    func launched(pid: pid_t, processStartTime: ProcessStartTime) -> ManagedServerRecord {
        ManagedServerRecord(
            pid: pid,
            host: host,
            port: port,
            binaryPath: binaryPath,
            processStartTime: processStartTime,
            startedAt: startedAt
        )
    }

    var endpoint: ConnectionEndpoint { ConnectionEndpoint(host: host, port: port) }

    var isIntent: Bool { pid == nil || processStartTime == nil }

    var identifiesLiveProcess: Bool {
        guard let pid, let processStartTime else { return false }
        return ProcessIdentity.isAlive(pid: pid, since: processStartTime)
    }
}

struct ManagedServerRecordStore: Sendable {
    let paths: ManagedPaths

    func load() -> ManagedServerRecord? {
        guard let data = try? Data(contentsOf: paths.managedServerFile) else { return nil }
        return try? JSONDecoder().decode(ManagedServerRecord.self, from: data)
    }

    func save(_ record: ManagedServerRecord) throws {
        try FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: paths.managedServerFile, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: paths.managedServerFile)
    }
}
