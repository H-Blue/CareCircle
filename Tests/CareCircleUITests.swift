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
    func testVisitRecordingSavesAndReopensAfterRelaunch() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Open menu"].tap()
        app.buttons["Record a doctor visit"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCTAssertTrue(app.buttons["Finish visit recording"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Open menu"].exists)
        XCTAssertTrue(app.staticTexts["Recording…"].waitForExistence(timeout: 30))
        let screenshot = app.screenshot()
        try? screenshot.pngRepresentation.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("CareCircle-Visit.png"))
        let image = XCTAttachment(screenshot: screenshot)
        image.name = "CareCircle-visit-recording"; image.lifetime = .keepAlways; add(image)
        app.buttons["Finish visit recording"].tap()
        XCTAssertTrue(app.buttons["Open menu"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        app.buttons["Open menu"].tap()
        app.buttons["Saved visits & AI summaries"].tap()
        let savedVisit = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Transcript & AI summary")).firstMatch
        XCTAssertTrue(savedVisit.waitForExistence(timeout: 5)); savedVisit.tap()
        XCTAssertTrue(app.buttons["AI summary"].waitForExistence(timeout: 5))
        app.buttons["Play / stop recording"].tap()
        XCTAssertFalse(app.staticTexts["This recording couldn’t play. Your transcript is available below."].exists)
        app.buttons["AI summary"].tap()
        XCTAssertTrue(app.staticTexts["AI summary"].waitForExistence(timeout: 5))
    }

}
