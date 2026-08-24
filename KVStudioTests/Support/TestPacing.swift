import Foundation

/// Timing constants in these suites were chosen on a developer's Mac. A shared CI runner spawns
/// processes and unwinds sockets several times more slowly, and none of the tests that carry these
/// constants assert a speed — they assert an outcome that a too-short budget hides behind a
/// timeout. Scaling there rather than widening every constant keeps local runs fast and honest.
enum TestPacing {
    static let factor: Int = ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 6

    static func scaled(_ duration: Duration) -> Duration { duration * factor }
}
