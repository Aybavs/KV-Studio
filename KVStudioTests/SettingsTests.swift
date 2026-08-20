import Testing
import Foundation
import SwiftUI
@testable import KV_Studio

@Suite
struct SettingsPreferencesTests {

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kv-settings-\(UUID().uuidString)", isDirectory: true)
        let paths = ManagedPaths(root: root)
        try paths.createDirectoryTree()
        return paths
    }

    @Test func newPreferencesHaveDefaults() throws {
        let prefs = Preferences.default
        #expect(prefs.appearance == .system)
        #expect(prefs.reopenLastConnection == true)
        #expect(prefs.autoCheckUpdates == true)
    }

    @Test func appearanceRoundTrips() throws {
        let paths = try makePaths()
        var prefs = Preferences.default
        prefs.appearance = .dark
        try PreferencesStore(paths: paths).savePreferences(prefs)
        let loaded = PreferencesStore(paths: paths).loadPreferences()
        #expect(loaded.appearance == .dark)
    }

    @Test func reopenLastConnectionRoundTrips() throws {
        let paths = try makePaths()
        var prefs = Preferences.default
        prefs.reopenLastConnection = false
        try PreferencesStore(paths: paths).savePreferences(prefs)
        #expect(PreferencesStore(paths: paths).loadPreferences().reopenLastConnection == false)
    }

    @Test func autoCheckUpdatesRoundTrips() throws {
        let paths = try makePaths()
        var prefs = Preferences.default
        prefs.autoCheckUpdates = false
        try PreferencesStore(paths: paths).savePreferences(prefs)
        #expect(PreferencesStore(paths: paths).loadPreferences().autoCheckUpdates == false)
    }

    @Test func oldPreferencesJSONWithoutNewKeysDecodesWithDefaults() throws {
        let paths = try makePaths()
        let oldJSON = #"{"localBindHost":"127.0.0.1","localPort":6380}"#
        try oldJSON.write(to: paths.preferencesFile, atomically: true, encoding: .utf8)
        let loaded = PreferencesStore(paths: paths).loadPreferences()
        #expect(loaded.appearance == .system)
        #expect(loaded.reopenLastConnection == true)
        #expect(loaded.autoCheckUpdates == true)
    }

    @Test @MainActor func settingsViewModelShowsStudioAndPaths() throws {
        let paths = try makePaths()
        let vm = SettingsViewModel(paths: paths)
        #expect(!vm.studioVersion.isEmpty)
        #expect(vm.applicationSupportPath == paths.root.path)
        #expect(!vm.bundledVersion.isEmpty)
        #expect(!vm.recommendedVersion.isEmpty)
    }

    @Test @MainActor func managedInstalledVersionIsNilWhenNoMetadata() throws {
        let paths = try makePaths()
        let vm = SettingsViewModel(paths: paths)
        #expect(vm.managedInstalledVersion == nil)
    }

    @Test @MainActor func managedInstalledVersionLoadsFromMetadata() throws {
        let paths = try makePaths()
        let meta = ["version": "1.2.3"]
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: paths.backendCurrentMetadata)
        let vm = SettingsViewModel(paths: paths)
        #expect(vm.managedInstalledVersion == "1.2.3")
    }
}

@Suite
struct AppearanceMappingTests {

    @Test func systemMapsToNilColorScheme() {
        #expect(Appearance.system.colorScheme == nil)
    }

    @Test func lightMapsToLight() {
        #expect(Appearance.light.colorScheme == .light)
    }

    @Test func darkMapsToDark() {
        #expect(Appearance.dark.colorScheme == .dark)
    }
}

@Suite
struct RestoreGateTests {

    @Test func shouldRestoreWhenPreferenceOn() {
        var prefs = Preferences.default
        prefs.reopenLastConnection = true
        #expect(SettingsViewModel.shouldRestore(prefs) == true)
    }

    @Test func shouldNotRestoreWhenPreferenceOff() {
        var prefs = Preferences.default
        prefs.reopenLastConnection = false
        #expect(SettingsViewModel.shouldRestore(prefs) == false)
    }
}

@Suite
struct BackendPolicyTests {

    @Test func wellFormedPolicyParses() throws {
        let json = #"{"schema":1,"minimumBackend":"1.1.0","bundledBackend":"1.1.0","recommendedBackend":"1.1.0"}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("policy-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let policy = BackendPolicy.load(from: url)
        #expect(policy.bundledBackend == "1.1.0")
        #expect(policy.recommendedBackend == "1.1.0")
        #expect(policy.minimumBackend == "1.1.0")
        #expect(policy.schema == 1)
    }

    @Test func missingFileFallsBackToDefaults() {
        let policy = BackendPolicy.load(from: nil)
        #expect(policy.bundledBackend == "1.1.0")
        #expect(policy.recommendedBackend == "1.1.0")
    }

    @Test func garbageFileFallsBackToDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let policy = BackendPolicy.load(from: url)
        #expect(policy.bundledBackend == "1.1.0")
    }

    @Test func bundlePolicyIsPresentAndValid() {
        let policy = BackendPolicy.loadFromBundle()
        #expect(policy.bundledBackend == "1.1.0")
        #expect(policy.recommendedBackend == "1.1.0")
        #expect(policy.schema == 1)
    }
}
