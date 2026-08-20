import Foundation

// What the user is shown. Sparkle's own windows are replaced by KV Studio's, so the driver
// translates its callbacks into this and the UI renders it.
enum AppUpdatePhase: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case found(version: String)
    case downloading(fraction: Double?)
    case extracting(fraction: Double)
    case readyToInstall
    case installing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .extracting, .installing: return true
        case .idle, .upToDate, .found, .readyToInstall, .failed: return false
        }
    }

    var isPresentable: Bool {
        self != .idle
    }
}
