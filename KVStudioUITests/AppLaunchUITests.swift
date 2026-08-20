import XCTest

@MainActor
final class AppLaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // Matches on accessibility identifiers, not on displayed text: macOS does not reliably surface
    // SwiftUI Text as an AX label here, and identifiers are what the app sets deliberately.
    func testAppLaunchesToItsConnectionScreen() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.staticTexts["app.title"].waitForExistence(timeout: 30),
            "The sidebar header never appeared"
        )
        XCTAssertTrue(
            app.staticTexts["connection.onboarding.title"].waitForExistence(timeout: 10),
            "The app did not land on its connection screen"
        )
        XCTAssertTrue(
            app.staticTexts["toolbar.status"].exists,
            "The toolbar status was not shown"
        )
    }
}
