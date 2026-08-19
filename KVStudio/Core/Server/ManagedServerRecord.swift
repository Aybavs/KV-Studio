import Darwin
import Foundation

struct ManagedServerRecord: Codable, Equatable, Sendable {
    let pid: pid_t
    let host: String
    let port: UInt16
    let binaryPath: String
    let processStartTime: ProcessStartTime
    let startedAt: Date

    var endpoint: ConnectionEndpoint { ConnectionEndpoint(host: host, port: port) }

    var identifiesLiveProcess: Bool {
        ProcessIdentity.isAlive(pid: pid, since: processStartTime)
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
