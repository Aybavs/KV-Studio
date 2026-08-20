import Foundation
import SwiftUI

enum Appearance: String, Codable, Sendable, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct Preferences: Equatable, Codable, Sendable {
    var localBindHost: String
    var localPort: UInt16
    var appearance: Appearance
    var reopenLastConnection: Bool
    var autoCheckUpdates: Bool

    static let `default` = Preferences(
        localBindHost: "127.0.0.1",
        localPort: 6380,
        appearance: .system,
        reopenLastConnection: true,
        autoCheckUpdates: true
    )

    private enum CodingKeys: String, CodingKey {
        case localBindHost, localPort, appearance, reopenLastConnection, autoCheckUpdates
    }

    init(localBindHost: String, localPort: UInt16, appearance: Appearance = .system, reopenLastConnection: Bool = true, autoCheckUpdates: Bool = true) {
        self.localBindHost = localBindHost
        self.localPort = localPort
        self.appearance = appearance
        self.reopenLastConnection = reopenLastConnection
        self.autoCheckUpdates = autoCheckUpdates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localBindHost = try c.decodeIfPresent(String.self, forKey: .localBindHost) ?? Preferences.default.localBindHost
        localPort = try c.decodeIfPresent(UInt16.self, forKey: .localPort) ?? Preferences.default.localPort
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        reopenLastConnection = try c.decodeIfPresent(Bool.self, forKey: .reopenLastConnection) ?? true
        autoCheckUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(localBindHost, forKey: .localBindHost)
        try c.encode(localPort, forKey: .localPort)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(reopenLastConnection, forKey: .reopenLastConnection)
        try c.encode(autoCheckUpdates, forKey: .autoCheckUpdates)
    }
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
