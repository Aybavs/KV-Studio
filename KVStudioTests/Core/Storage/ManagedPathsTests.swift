import Foundation
import Testing
@testable import KV_Studio

struct ManagedPathsTests {

    private func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func derivesLayoutFromInjectedRoot() {
        let root = makeTempRoot()
        let paths = ManagedPaths(root: root)

        #expect(paths.backendCurrentDir.path == root.appendingPathComponent("backend/current").path)
        #expect(paths.backendPreviousDir.path == root.appendingPathComponent("backend/previous").path)
        #expect(paths.backendStagingDir.path == root.appendingPathComponent("backend/staging").path)
        #expect(paths.backendCurrentBinary.path == root.appendingPathComponent("backend/current/kv-server").path)
        #expect(paths.backendCurrentMetadata.path == root.appendingPathComponent("backend/current/metadata.json").path)
        #expect(paths.dataDir.path == root.appendingPathComponent("data").path)
        #expect(paths.aofFile.path == root.appendingPathComponent("data/appendonly.aof").path)
        #expect(paths.logsDir.path == root.appendingPathComponent("logs").path)
        #expect(paths.logFile.path == root.appendingPathComponent("logs/kv-server.log").path)
        #expect(paths.stateDir.path == root.appendingPathComponent("state").path)
        #expect(paths.preferencesFile.path == root.appendingPathComponent("state/preferences.json").path)
        #expect(paths.connectionsFile.path == root.appendingPathComponent("state/connections.json").path)
        #expect(paths.managedServerFile.path == root.appendingPathComponent("state/managed-server.json").path)
    }

    @Test func computingPathsDoesNotTouchDisk() {
        let root = makeTempRoot()
        let paths = ManagedPaths(root: root)
        _ = paths.stateDir
        _ = paths.preferencesFile

        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func createDirectoryTreeCreatesAllDirectories() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ManagedPaths(root: root)

        try paths.createDirectoryTree()

        var isDirectory: ObjCBool = false
        for dir in [paths.backendCurrentDir, paths.backendPreviousDir, paths.backendStagingDir,
                    paths.dataDir, paths.logsDir, paths.stateDir] {
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    @Test func createDirectoryTreeIsIdempotent() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ManagedPaths(root: root)

        try paths.createDirectoryTree()
        try paths.createDirectoryTree()

        #expect(FileManager.default.fileExists(atPath: paths.stateDir.path))
    }

    @Test func resolveDefaultNeverPointsAtRealApplicationSupport() throws {
        let paths = try ManagedPaths.resolveDefault()
        let realAppSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )

        #expect(paths.root.path == realAppSupport.appendingPathComponent("KV Studio").path)
    }
}
