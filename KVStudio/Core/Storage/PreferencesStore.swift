import Foundation

struct Preferences: Equatable, Codable, Sendable {
    var localBindHost: String
    var localPort: UInt16

    static let `default` = Preferences(localBindHost: "127.0.0.1", localPort: 6380)
}

struct PreferencesStore: Sendable {
    let paths: ManagedPaths

    private func clamped(_ preferences: Preferences) -> Preferences {
        var preferences = preferences
        if preferences.localPort == 0 {
            preferences.localPort = Preferences.default.localPort
        }
        return preferences
    }

    func loadPreferences() -> Preferences {
        guard let data = try? Data(contentsOf: paths.preferencesFile),
              let preferences = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return .default
        }
        return clamped(preferences)
    }

    func savePreferences(_ preferences: Preferences) throws {
        let data = try JSONEncoder().encode(clamped(preferences))
        try data.write(to: paths.preferencesFile, options: .atomic)
    }

    func loadLastConnectionTarget() -> ConnectionTarget? {
        guard let data = try? Data(contentsOf: paths.connectionsFile),
              let target = try? JSONDecoder().decode(ConnectionTarget.self, from: data) else {
            return nil
        }
        return target
    }

    func saveLastConnectionTarget(_ target: ConnectionTarget) throws {
        let data = try JSONEncoder().encode(target)
        try data.write(to: paths.connectionsFile, options: .atomic)
    }
}
