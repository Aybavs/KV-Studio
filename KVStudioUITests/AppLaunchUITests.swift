import XCTest

@MainActor
final class AppLaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAppLaunchesToConnectionScreen() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.staticTexts["KV Studio"].waitForExistence(timeout: 10),
            "The app did not present its launch screen"
        )
    }
}
