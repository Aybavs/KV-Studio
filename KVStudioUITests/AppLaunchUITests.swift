import XCTest

@MainActor
final class AppLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let running = XCUIApplication()
        if running.state != .notRunning {
            _ = running.wait(for: .notRunning, timeout: 10)
        }
        try XCTSkipUnless(
            running.state == .notRunning,
            "A KV Studio instance is already running; stop it, including an Xcode Run session, since a debugger-attached app refuses termination."
        )
    }

    // Matches on identifier through `node(_:)`, not on element type: the sidebar header and the
    // toolbar status are combined accessibility elements, not static text.
    func testAppLaunchesToItsConnectionScreen() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.node("app.title").waitForExistence(timeout: 30),
            "The sidebar header never appeared"
        )
        XCTAssertTrue(
            app.staticTexts["connection.onboarding.title"].waitForExistence(timeout: 10),
            "The app did not land on its connection screen"
        )
        XCTAssertTrue(
            app.node("toolbar.status").exists,
            "The toolbar status was not shown"
        )
    }
}
