import Testing
@testable import KV_Studio

/// Proves the unit-test bundle is wired to the app target and can run.
/// Real coverage begins with the RESP codec in Task 4.
@Test func appTargetIsTestable() {
    _ = ConnectionPlaceholderView()
}
