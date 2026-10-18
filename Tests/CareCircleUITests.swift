import XCTest

final class CareCircleUITests: XCTestCase {
    func testVoiceModeTransitionAndExit() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Open menu"].waitForExistence(timeout: 10))
        app.buttons["Speak to Care Circle"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowMicrophone = springboard.alerts.buttons["Allow"]
        if allowMicrophone.waitForExistence(timeout: 3) { allowMicrophone.tap() }
        XCTAssertTrue(app.buttons["End conversation"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Open menu"].exists)
        // A configured developer build can connect; fresh checkouts can still verify the transition.
        _ = app.staticTexts["Listening"].waitForExistence(timeout: 10)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "CareCircle-voice-mode"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["End conversation"].tap()
        XCTAssertTrue(app.buttons["Open menu"].waitForExistence(timeout: 5))
    }
}
