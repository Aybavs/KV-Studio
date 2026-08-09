import Testing
@testable import KV_Studio

/// Proves the unit-test bundle is wired to the app target.
@Test func appTargetIsTestable() {
    _ = ConnectionPlaceholderView()
}
