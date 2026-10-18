import XCTest

final class EncircleUITests: XCTestCase {
    func testPhoneSignInCreateCircleAndJoinAsFamily() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-account-flow"]
        app.launchEnvironment["ENCIRCLE_ACCOUNT_TEST_ADDRESS"] = "http://127.0.0.1:8799"
        app.launch()
        app.buttons["Open menu"].tap()
        app.buttons["Your account"].tap()
        if app.buttons["Sign out"].exists { app.buttons["Sign out"].tap() }
        func signIn(_ name: String, _ phone: String) {
            XCTAssertTrue(app.textFields["Account name"].waitForExistence(timeout: 5))
            app.textFields["Account name"].tap(); app.textFields["Account name"].typeText(name)
            app.textFields["Account phone"].tap(); app.textFields["Account phone"].typeText(phone)
            app.buttons["Text me a sign-in code"].tap()
            XCTAssertTrue(app.textFields["Account verification code"].waitForExistence(timeout: 5))
            app.textFields["Account verification code"].tap(); app.textFields["Account verification code"].typeText("654321")
            app.buttons["Sign in"].tap()
            XCTAssertTrue(app.buttons["Create a circle"].waitForExistence(timeout: 5))
        }
        signIn("Demo Leader", "+15555550123")
        app.buttons["Create a circle"].tap()
        app.textFields["Circle name"].tap(); app.textFields["Circle name"].typeText("Demo circle")
        app.textFields["Who are you caring for?"].tap(); app.textFields["Who are you caring for?"].typeText("Demo patient")
        app.buttons["Create circle"].tap()
        let circle = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Demo circle")).firstMatch
        XCTAssertTrue(circle.waitForExistence(timeout: 5)); circle.tap()
        XCTAssertTrue(app.staticTexts["Circle invitation code"].waitForExistence(timeout: 5))
        let invitation = app.staticTexts["Circle invitation code"].label
        XCTAssertEqual(invitation.count, 16)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Encircle-synthetic-circle"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Sign out"].tap()
        signIn("Demo Family", "+15555550124")
        app.buttons["Join a circle"].tap()
        app.textFields["Invitation code"].tap(); app.textFields["Invitation code"].typeText(invitation)
        app.buttons["Join circle"].tap()
        XCTAssertTrue(circle.waitForExistence(timeout: 5)); circle.tap()
        XCTAssertTrue(app.staticTexts["Demo Leader"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Demo Family"].exists)
        XCTAssertTrue(app.staticTexts["Family"].exists)
        XCTAssertFalse(app.staticTexts["Circle invitation code"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Sign out"].tap()
    }

    func testSMSConsentStartsUncheckedAndShowsActualDisclosure() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Open menu"].tap()
        app.buttons["Apple Calendar & transport"].tap()
        app.buttons["SMS consent & preferences"].tap()
        XCTAssertTrue(app.staticTexts["SMS disclosure"].waitForExistence(timeout: 30))
        let disclosure = app.staticTexts["SMS disclosure"].label
        XCTAssertTrue(disclosure.contains("Message and data rates may apply"))
        XCTAssertTrue(disclosure.contains("STOP")); XCTAssertTrue(disclosure.contains("HELP"))
        let top = XCTAttachment(screenshot: app.screenshot())
        top.name = "Encircle-SMS-disclosure"; top.lifetime = .keepAlways; add(top)
        let checkbox = app.buttons["SMS consent checkbox"]
        for _ in 0..<3 { if checkbox.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(checkbox.isHittable)
        XCTAssertEqual(checkbox.value as? String, "Unchecked")
        let save = app.buttons["Save SMS consent"]
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(app.textFields["SMS consent name"].value as? String, "Your name")
        XCTAssertEqual(app.textFields["SMS consent phone"].value as? String, "Your mobile number")
        let blank = XCTAttachment(screenshot: app.screenshot())
        blank.name = "Encircle-SMS-blank-opt-in"; blank.lifetime = .keepAlways; add(blank)
        checkbox.tap()
        XCTAssertEqual(checkbox.value as? String, "Checked")
        XCTAssertFalse(save.isEnabled)
        checkbox.tap()
        XCTAssertEqual(checkbox.value as? String, "Unchecked")
        // Deliberately do not submit: a UI test must not fabricate the owner's consent.
        for title in ["Privacy Policy", "Terms & Conditions"] {
            for _ in 0..<5 {
                if app.buttons[title].firstMatch.isHittable { break }
                app.swipeUp()
            }
            app.buttons[title].firstMatch.tap()
            let copy = app.buttons["Copy " + title + " URL"]
            XCTAssertTrue(copy.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[title == "Privacy Policy" ? "Encircle SMS Privacy Notice" : "Encircle SMS Program Terms"].exists)
            copy.tap()
            XCTAssertEqual(copy.label, "URL copied")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }
    func testCoordinatorShowsCloudPlansAndSimulationMode() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Open menu"].tap()
        app.buttons["Apple Calendar & transport"].tap()
        app.buttons["Care coordinator"].tap()
        XCTAssertTrue(app.staticTexts["Terraica"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Demo simulation · no texts sent"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "To appointment:")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Ride home:")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Encircle-coordinator-cloud"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testCalendarSyncAndTransportNotesPersistWithoutDuplicates() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-calendar-sync"]
        app.launch()
        app.buttons["Open menu"].tap()
        app.buttons["Apple Calendar & transport"].tap()
        let first = app.buttons["scheduled-demo-appointment-2026-11-03"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        let name = app.textFields["Care recipient name"]
        name.tap()
        if let value = name.value as? String { name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        name.typeText("Demo Care Recipient\n")
        let connect = app.buttons["Connect Apple Calendar"]
        if connect.exists { connect.tap() } else { app.buttons["Save & sync calendar"].tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Allow' AND NOT label CONTAINS[c] 'Don' AND NOT label CONTAINS[c] 'Only'")).firstMatch
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        let synced = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "3 appointments updated")).firstMatch
        guard synced.waitForExistence(timeout: 30) else {
            XCTFail("Calendar sync did not finish: " + app.debugDescription); return
        }
        first.tap()
        let taking = app.textFields["Taking them"]
        let unavailable = app.textFields["Not taking them"]
        taking.tap()
        if let value = taking.value as? String { taking.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        taking.typeText("Alex\n")
        unavailable.tap()
        if let value = unavailable.value as? String { unavailable.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        unavailable.typeText("Jordan\n")
        app.buttons["Save transport details"].tap()
        XCTAssertTrue(synced.waitForExistence(timeout: 30))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Encircle-calendar-transport"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.launch()
        app.buttons["Open menu"].tap()
        app.buttons["Apple Calendar & transport"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 20)); first.tap()
        XCTAssertEqual(taking.value as? String, "Alex")
        XCTAssertEqual(unavailable.value as? String, "Jordan")
        // Debug verification in the EventKit adapter also checks one matching event per slot
        // and exact transport notes after every real native calendar save, including relaunch.
    }

    func testHomeAnticipatesVisitSummary() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-summary-home"]
        app.launch()
        let recap = app.staticTexts["Home visit summary"]
        XCTAssertTrue(recap.waitForExistence(timeout: 90))
        XCTAssertLessThanOrEqual(recap.label.split(whereSeparator: \.isWhitespace).count, 75)
        XCTAssertFalse(recap.label.localizedCaseInsensitiveContains("fracture"))
        XCTAssertFalse(app.staticTexts["Visit saved. Find your transcript and AI summary in the top-left menu."].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Encircle-home-recap"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(recap.waitForExistence(timeout: 10))
        app.buttons["View appointment"].tap()
        XCTAssertTrue(app.buttons["AI summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Your X-ray shows no fracture")).firstMatch.exists)
        app.buttons["Back to home"].tap()
        XCTAssertTrue(app.buttons["Got it"].waitForExistence(timeout: 5))
        app.buttons["Got it"].tap()
        XCTAssertFalse(recap.exists)
        XCTAssertTrue(app.staticTexts["Hi, what can I\nhelp with?"].exists)
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "Encircle-home"; home.lifetime = .keepAlways; add(home)
    }

    func testVoiceModeTransitionAndExit() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Open menu"].waitForExistence(timeout: 10))
        app.buttons["Speak to Encircle"].tap()
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
        attachment.name = "Encircle-voice-mode"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["End conversation"].tap()
        XCTAssertTrue(app.buttons["Open menu"].waitForExistence(timeout: 5))
    }
    func testVisitRecordingSavesAndReopensAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-record-visit"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCTAssertTrue(app.buttons["Finish visit recording"].waitForExistence(timeout: 45))
        XCTAssertFalse(app.buttons["Open menu"].exists)
        XCTAssertTrue(app.staticTexts["Recording…"].waitForExistence(timeout: 30))
        let screenshot = app.screenshot()
        try? screenshot.pngRepresentation.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("Encircle-Visit.png"))
        let image = XCTAttachment(screenshot: screenshot)
        image.name = "Encircle-visit-recording"; image.lifetime = .keepAlways; add(image)
        app.buttons["Finish visit recording"].tap()
        XCTAssertTrue(app.buttons["Open menu"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = []; app.launch()
        app.buttons["Open menu"].tap()
        let savedVisit = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Latest appointment")).firstMatch
        XCTAssertTrue(savedVisit.waitForExistence(timeout: 5))
        let visitIdentifier = savedVisit.identifier
        let menuPresented = expectation(for: NSPredicate { _, _ in
            app.navigationBars["Appointments"].frame.minY < 100 && savedVisit.isHittable
        }, evaluatedWith: app)
        wait(for: [menuPresented], timeout: 5)
        let menuImage = XCTAttachment(screenshot: app.screenshot())
        menuImage.name = "Encircle-appointments-menu"; menuImage.lifetime = .keepAlways; add(menuImage)
        savedVisit.swipeLeft()
        XCTAssertTrue(app.buttons["Archive"].firstMatch.waitForExistence(timeout: 5))
        savedVisit.swipeRight()
        savedVisit.tap()
        XCTAssertTrue(app.buttons["AI summary"].waitForExistence(timeout: 5))
        app.buttons["Play / stop recording"].tap()
        XCTAssertFalse(app.staticTexts["This recording couldn’t play. Your transcript is available below."].exists)
        app.buttons["AI summary"].tap()
        XCTAssertTrue(app.staticTexts["AI summary"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let transcriptImage = XCTAttachment(screenshot: app.screenshot())
        transcriptImage.name = "Encircle-cream-transcript"; transcriptImage.lifetime = .keepAlways; add(transcriptImage)
        app.swipeLeft()
        XCTAssertTrue(app.navigationBars["Appointments"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[visitIdentifier].exists)
        app.terminate(); app.launch()
        app.buttons["Open menu"].tap()
        XCTAssertFalse(app.buttons[visitIdentifier].exists)
        app.buttons["Archived appointments"].tap()
        XCTAssertTrue(app.navigationBars["Archived appointments"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "2026")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 5))
        app.buttons["Restore"].tap()
        XCTAssertTrue(app.buttons["Archive"].exists)
    }

    func testElevenLabsRecordingToolOpensRecorder() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-visit-tool"]
        app.launch()
        app.buttons["Speak to Encircle"].tap()
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
