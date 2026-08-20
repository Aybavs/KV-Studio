import Foundation

enum SidebarGroup: String, CaseIterable, Equatable, Sendable {
    case browse
    case manage
    case settings

    var title: String? {
        switch self {
        case .browse: return "BROWSE"
        case .manage: return "MANAGE"
        case .settings: return nil
        }
    }
}

enum AppRoute: String, CaseIterable, Identifiable, Hashable, Sendable {
    case browser
    case console
    case server
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser: return "Browser"
        case .console: return "Console"
        case .server: return "Server"
        case .logs: return "Logs"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .browser: return "internaldrive"
        case .console: return "terminal"
        case .server: return "server.rack"
        case .logs: return "doc.text"
        case .settings: return "gearshape"
        }
    }

    var group: SidebarGroup {
        switch self {
        case .browser, .console: return .browse
        case .server, .logs: return .manage
        case .settings: return .settings
        }
    }

    static var sidebarGroups: [SidebarGroup] { [.browse, .manage, .settings] }

    static func routes(in group: SidebarGroup) -> [AppRoute] {
        allCases.filter { $0.group == group }
    }
}
