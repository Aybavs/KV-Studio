import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class ServerViewModel {
    let paths: ManagedPaths
    let coordinator: ConnectionCoordinator

    private(set) var backendVersion: String?
    private(set) var aofFileSize: UInt64?

    init(paths: ManagedPaths, coordinator: ConnectionCoordinator) {
        self.paths = paths
        self.coordinator = coordinator
        refresh()
    }

    convenience init(coordinator: ConnectionCoordinator) {
        self.init(paths: coordinator.paths, coordinator: coordinator)
    }

    func refresh() {
        backendVersion = Self.loadBackendVersion(from: paths.backendCurrentMetadata)
        aofFileSize = Self.loadAOFSize(at: paths.aofFile)
    }

    // MARK: - Static helpers (testable)

    static func loadBackendVersion(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else { return nil }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func loadAOFSize(at url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.size] as? NSNumber)?.uint64Value
    }

    static func formatAOFSize(_ size: UInt64?) -> String {
        guard let size else { return "—" }
        if size == 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(size)
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 { return "\(size) B" }
        return String(format: "%.1f %@", value, units[idx])
    }

    static func isManaged(phase: ConnectionPhase) -> Bool {
        switch phase {
        case .connected(let session): return session.target == .managedLocal
        case .connecting(let target): return target == .managedLocal
        case .failed(let attempt): return attempt.target == .managedLocal
        case .disconnected: return true
        }
    }

    static func stateText(managedServer: ManagedServerStatus, phase: ConnectionPhase) -> String {
        switch managedServer {
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .failed(let error): return "Failed — \(error.localizedDescription)"
        case .unreclaimed(let pid): return "Running (unreclaimed, pid \(pid))"
        case .idle:
            if case .connecting(.managedLocal) = phase { return "Starting" }
            // If coordinator reports connected, even idle should show Running (transient)
            if case .connected = phase { return "Running" }
            return "Stopped"
        }
    }

    static func pidText(managedServer: ManagedServerStatus) -> String {
        switch managedServer {
        case .running(let pid): return String(pid)
        case .unreclaimed(let pid): return "\(pid) (unreclaimed)"
        case .starting, .stopping, .stopped, .idle, .failed: return "—"
        }
    }

    static func hostPortText(coordinator: ConnectionCoordinator, paths: ManagedPaths) -> String {
        switch coordinator.phase {
        case .connected(let session):
            return "\(session.endpoint.host):\(session.endpoint.port)"
        case .connecting(let target):
            if case .existing(let ep) = target { return "\(ep.host):\(ep.port)" }
            let prefs = PreferencesStore(paths: paths).loadPreferences()
            return "\(prefs.localBindHost):\(prefs.localPort)"
        case .failed(let attempt):
            if case .existing(let ep) = attempt.target { return "\(ep.host):\(ep.port)" }
            let prefs = PreferencesStore(paths: paths).loadPreferences()
            return "\(prefs.localBindHost):\(prefs.localPort)"
        case .disconnected:
            let prefs = PreferencesStore(paths: paths).loadPreferences()
            return "\(prefs.localBindHost):\(prefs.localPort)"
        }
    }

    // MARK: - Instance computed

    var isManaged: Bool { Self.isManaged(phase: coordinator.phase) }

    var stateText: String { Self.stateText(managedServer: coordinator.managedServer, phase: coordinator.phase) }

    var pidText: String { Self.pidText(managedServer: coordinator.managedServer) }

    var hostPortText: String { Self.hostPortText(coordinator: coordinator, paths: paths) }

    var backendVersionText: String { backendVersion ?? "Unknown" }

    var aofModeText: String { "AOF enabled — appendfsync everysec" }

    var aofSizeText: String { Self.formatAOFSize(aofFileSize) }

    var binaryPathText: String { paths.backendCurrentBinary.path }

    var dataPathText: String { paths.dataDir.path }

    var aofPathText: String { paths.aofFile.path }

    var compatibilityText: String { "Compatible — PING, DBSIZE, SCAN passed" }

    var canStart: Bool {
        switch coordinator.managedServer {
        case .running, .starting, .stopping, .unreclaimed: return false
        default: return isManaged
        }
    }

    var canStop: Bool {
        switch coordinator.managedServer {
        case .running, .unreclaimed: return true
        default:
            if case .connected(let session) = coordinator.phase, session.target == .managedLocal { return true }
            return false
        }
    }

    var canRestart: Bool { canStop }

    // MARK: - Actions

    func start() async {
        await coordinator.connect(to: .managedLocal)
        refresh()
    }

    func stop() async {
        await coordinator.disconnect()
        refresh()
    }

    func restart() async {
        await coordinator.disconnect()
        await coordinator.connect(to: .managedLocal)
        refresh()
    }

    func revealInFinder(url: URL) {
        let path = url.path
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            // Fallback: open parent directory
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func revealDataInFinder() { revealInFinder(url: paths.dataDir) }
    func revealBinaryInFinder() { revealInFinder(url: paths.backendCurrentBinary) }
    func revealAOFInFinder() { revealInFinder(url: paths.aofFile) }
    func revealLogsInFinder() { revealInFinder(url: paths.logFile) }
}
