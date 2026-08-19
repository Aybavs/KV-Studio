import Foundation
import Testing
@testable import KV_Studio

struct PreferencesStoreTests {

    private func makeStore() -> PreferencesStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = ManagedPaths(root: root)
        try? paths.createDirectoryTree()
        return PreferencesStore(paths: paths)
    }

    @Test func loadPreferencesReturnsDefaultsWhenFileMissing() {
        let store = makeStore()
        let preferences = store.loadPreferences()

        #expect(preferences.localBindHost == "127.0.0.1")
        #expect(preferences.localPort == 6380)
    }

    @Test func savedPreferencesRoundTrip() throws {
        let store = makeStore()
        try store.savePreferences(Preferences(localBindHost: "0.0.0.0", localPort: 7000))

        let loaded = store.loadPreferences()
        #expect(loaded.localBindHost == "0.0.0.0")
        #expect(loaded.localPort == 7000)
    }

    @Test func loadPreferencesReturnsDefaultsWhenFileIsCorrupt() throws {
        let store = makeStore()
        try Data("not json at all {{{".utf8).write(to: store.paths.preferencesFile, options: .atomic)

        let preferences = store.loadPreferences()
        #expect(preferences.localBindHost == "127.0.0.1")
        #expect(preferences.localPort == 6380)
    }

    @Test func savingPortZeroClampsToDefault() throws {
        let store = makeStore()
        try store.savePreferences(Preferences(localBindHost: "127.0.0.1", localPort: 0))

        let loaded = store.loadPreferences()
        #expect(loaded.localPort == 6380)
    }

    @Test func loadLastConnectionTargetReturnsNilWhenFileMissing() {
        let store = makeStore()
        #expect(store.loadLastConnectionTarget() == nil)
    }

    @Test func loadLastConnectionTargetReturnsNilWhenFileIsCorrupt() throws {
        let store = makeStore()
        try Data("garbage".utf8).write(to: store.paths.connectionsFile, options: .atomic)

        #expect(store.loadLastConnectionTarget() == nil)
    }

    @Test func lastConnectionTargetRoundTripsManagedLocal() throws {
        let store = makeStore()
        try store.saveLastConnectionTarget(.managedLocal)

        #expect(store.loadLastConnectionTarget() == .managedLocal)
    }

    @Test func lastConnectionTargetRoundTripsExistingEndpoint() throws {
        let store = makeStore()
        let target = ConnectionTarget.existing(ConnectionEndpoint(host: "10.0.0.5", port: 6399))
        try store.saveLastConnectionTarget(target)

        #expect(store.loadLastConnectionTarget() == target)
    }

    @Test func connectionTargetOnDiskShapeUsesKindDiscriminator() throws {
        let store = makeStore()
        try store.saveLastConnectionTarget(.existing(ConnectionEndpoint(host: "192.168.1.1", port: 1234)))

        let data = try Data(contentsOf: store.paths.connectionsFile)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["kind"] as? String == "existing")
        #expect(json["host"] as? String == "192.168.1.1")
        #expect(json["port"] as? Int == 1234)
    }
}
