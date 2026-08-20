import Foundation

struct ManagedPaths: Sendable {
    let root: URL

    var backendDir: URL { root.appendingPathComponent("backend", isDirectory: true) }
    var backendCurrentDir: URL { backendDir.appendingPathComponent("current", isDirectory: true) }
    var backendPreviousDir: URL { backendDir.appendingPathComponent("previous", isDirectory: true) }
    var backendStagingDir: URL { backendDir.appendingPathComponent("staging", isDirectory: true) }
    var backendCurrentBinary: URL { backendCurrentDir.appendingPathComponent("kv-server", isDirectory: false) }
    var backendCurrentMetadata: URL { backendCurrentDir.appendingPathComponent("metadata.json", isDirectory: false) }

    var dataDir: URL { root.appendingPathComponent("data", isDirectory: true) }
    var aofFile: URL { dataDir.appendingPathComponent("appendonly.aof", isDirectory: false) }

    var logsDir: URL { root.appendingPathComponent("logs", isDirectory: true) }
    var logFile: URL { logsDir.appendingPathComponent("kv-server.log", isDirectory: false) }

    var stateDir: URL { root.appendingPathComponent("state", isDirectory: true) }
    var preferencesFile: URL { stateDir.appendingPathComponent("preferences.json", isDirectory: false) }
    var connectionsFile: URL { stateDir.appendingPathComponent("connections.json", isDirectory: false) }
    var managedServerFile: URL { stateDir.appendingPathComponent("managed-server.json", isDirectory: false) }

    func createDirectoryTree() throws {
        let directories = [backendCurrentDir, backendPreviousDir, backendStagingDir, dataDir, logsDir, stateDir]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func resolveDefault() throws -> ManagedPaths {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return ManagedPaths(root: appSupport.appendingPathComponent("KV Studio", isDirectory: true))
    }
}
