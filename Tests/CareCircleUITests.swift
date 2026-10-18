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
        XCTAssertTrue(app.buttons["Pause microphone"].waitForExistence(timeout: 30))
        app.buttons["Pause microphone"].tap()
        XCTAssertTrue(app.buttons["Resume microphone"].waitForExistence(timeout: 5))
        app.buttons["Resume microphone"].tap()
        XCTAssertTrue(app.buttons["Pause microphone"].waitForExistence(timeout: 5))
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
        let savedVisit = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Latest appointment")).firstMatch
        XCTAssertTrue(savedVisit.waitForExistence(timeout: 5))
        let menuPresented = expectation(for: NSPredicate { _, _ in
            app.navigationBars["Appointments"].frame.minY < 100 && savedVisit.isHittable
        }, evaluatedWith: app)
        wait(for: [menuPresented], timeout: 5)
        let menuImage = XCTAttachment(screenshot: app.screenshot())
        menuImage.name = "CareCircle-appointments-menu"; menuImage.lifetime = .keepAlways; add(menuImage)
        savedVisit.tap()
        XCTAssertTrue(app.buttons["AI summary"].waitForExistence(timeout: 5))
        app.buttons["Play / stop recording"].tap()
        XCTAssertFalse(app.staticTexts["This recording couldn’t play. Your transcript is available below."].exists)
        app.buttons["AI summary"].tap()
        XCTAssertTrue(app.staticTexts["AI summary"].waitForExistence(timeout: 5))
    }

    func testElevenLabsRecordingToolOpensRecorder() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-visit-tool"]
        app.launch()
        app.buttons["Speak to Care Circle"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let openedOrFailed = expectation(for: NSPredicate { _, _ in
            app.buttons["Finish visit recording"].exists || app.staticTexts["Voice paused"].exists
        }, evaluatedWith: app)
        wait(for: [openedOrFailed], timeout: 60)
        guard app.buttons["Finish visit recording"].exists else {
            XCTFail("The ElevenLabs session failed before opening the native recorder."); return
        }
        XCTAssertTrue(app.staticTexts["Recording…"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["End conversation"].exists)
        app.buttons["Finish visit recording"].tap()
        XCTAssertTrue(app.buttons["Open menu"].waitForExistence(timeout: 10))
    }

}
