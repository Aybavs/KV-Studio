import Foundation

struct LogsAutoscrollState: Equatable, Sendable {
    var isAutoscrollEnabled: Bool
    var isPaused: Bool

    var shouldAutoscroll: Bool { isAutoscrollEnabled && !isPaused }
}
