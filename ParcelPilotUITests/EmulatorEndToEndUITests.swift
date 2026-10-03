import XCTest

/// Full stack against the Firebase Emulator Suite: Firebase Auth (emulator test account) → Firestore
/// with rules → callable functions (resolveAddress + requestOptimization with the emulator test
/// provider) → delivery outcomes. Runs only when the emulators are up:
///
///   cd firebase && npm run emulators
///   xcrun simctl privacy "iPhone 17" grant location com.example.parcelpilot
///   xcrun simctl location "iPhone 17" set 48.4284,-123.3656
///   TEST_RUNNER_PP_EMULATOR=1 xcodebuild test ... -only-testing:ParcelPilotUITests/EmulatorEndToEndUITests \
///     CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=   (signed: Firebase Auth needs the keychain)
///
/// Afterwards `node firebase/scripts/verify-emulator-e2e.mjs` checks the server-side documents.
final class EmulatorEndToEndUITests: XCTestCase {
    func testEndToEndAgainstEmulators() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PP_EMULATOR"] == "1", "Set TEST_RUNNER_PP_EMULATOR=1 with the emulators running")
        let app = XCUIApplication()
        app.launchArguments = ["-PPUseFirebaseEmulators", "YES", "-PPDemoMode", "NO", "-PPDisableAnimations", "YES", "-PPSignOutOnLaunch", "YES"]
        app.launch()

        func shot(_ name: String) {
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        func scrollTo(_ e: XCUIElement) {
            var n = 0
            while !(e.exists && e.isHittable) && n < 10 { app.collectionViews.firstMatch.swipeUp(); n += 1 }
        }

        // Sign in (anonymous auth, emulator only).
        if app.buttons["emulatorSignIn"].waitForExistence(timeout: 15) {
            shot("e2e-01-sign-in")
            app.buttons["emulatorSignIn"].tap()
        }
        if app.buttons["allRoutes"].waitForExistence(timeout: 5) { app.buttons["allRoutes"].tap() }
        XCTAssertTrue(app.buttons["newRoute"].waitForExistence(timeout: 20))
        app.buttons["newRoute"].tap()

        // Route with a start location typed (verified through the resolveAddress callable).
        XCTAssertTrue(app.buttons["saveRoute"].waitForExistence(timeout: 10))
        app.buttons["saveRoute"].tap()

        XCTAssertTrue(app.buttons["addStops"].waitForExistence(timeout: 20))
        app.buttons["addStops"].tap()
        app.buttons["addPaste"].tap()
        let editor = app.textViews["pasteField"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("Unit 204, 123 Example St, Victoria BC V8W 1A1\n45 Sample Ave, Victoria BC V8V 2B2\n9 Mock Cres, Victoria BC V8R 3C3\nExample St, Victoria BC V8W 1B2\n")
        app.buttons["pasteReview"].tap()
        XCTAssertTrue(app.staticTexts["Row 4"].waitForExistence(timeout: 10))
        let importButton = app.buttons["importNow"]
        scrollTo(importButton)
        importButton.tap()
        XCTAssertTrue(app.buttons["optimize"].waitForExistence(timeout: 30))
        shot("e2e-02-imported")

        // Optimize from the device's current location (the run script grants location permission and
        // sets a simulated location with simctl before the test).
        app.buttons["optimize"].tap()
        XCTAssertTrue(app.buttons["calculate"].waitForExistence(timeout: 10))
        addUIInterruptionMonitor(withDescription: "Location permission") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.buttons["calculate"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() } else { app.swipeUp(velocity: .slow) }
        // Section headers are upper-cased on iOS 17/18, so match case-insensitively.
        let proposedPlan = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Proposed plan")).firstMatch
        XCTAssertTrue(proposedPlan.waitForExistence(timeout: 60), "Callable optimization result arrives through the job document")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Emulator test provider'")).firstMatch.exists)
        shot("e2e-03-proposal")
        let apply = app.buttons["applyPlan"]
        scrollTo(apply)
        apply.tap()

        app.segmentedControls["workspaceMode"].buttons["Deliver"].tap()
        XCTAssertTrue(app.buttons["delivered"].waitForExistence(timeout: 10))
        app.buttons["delivered"].tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5))
        shot("e2e-04-delivered")
        // Let the write reach the emulator.
        XCTAssertTrue(app.descendants(matching: .any)["syncStatus"].waitForExistence(timeout: 5))
        sleep(3)
    }

    /// Address suggestions through the `suggestAddresses` callable (emulator test provider): typing shows
    /// a suggestion, and picking it opens the confirmation card already checked via `resolveAddress`.
    func testAddressSuggestionAgainstEmulators() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PP_EMULATOR"] == "1", "Set TEST_RUNNER_PP_EMULATOR=1 with the emulators running")
        let app = XCUIApplication()
        app.launchArguments = ["-PPUseFirebaseEmulators", "YES", "-PPDemoMode", "NO", "-PPDisableAnimations", "YES", "-PPSignOutOnLaunch", "YES"]
        app.launch()

        if app.buttons["emulatorSignIn"].waitForExistence(timeout: 15) { app.buttons["emulatorSignIn"].tap() }
        if app.buttons["allRoutes"].waitForExistence(timeout: 5) { app.buttons["allRoutes"].tap() }
        XCTAssertTrue(app.buttons["newRoute"].waitForExistence(timeout: 20))
        app.buttons["newRoute"].tap()
        XCTAssertTrue(app.buttons["saveRoute"].waitForExistence(timeout: 10))
        app.buttons["saveRoute"].tap()

        XCTAssertTrue(app.buttons["addStops"].waitForExistence(timeout: 20))
        app.buttons["addStops"].tap()
        app.buttons["addManual"].tap()
        let field = app.textViews["manualAddressField"].exists ? app.textViews["manualAddressField"] : app.textFields["manualAddressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("45 Sample Ave, Victoria BC V8V 2B2")

        let suggestion = app.buttons["suggestion.0"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 15), "Typing shows a suggestion from the suggestAddresses callable")
        XCTAssertTrue(app.staticTexts["Suggestions from Google Maps"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "suggest-01-suggestions"
        shot.lifetime = .keepAlways
        add(shot)
        suggestion.tap()

        XCTAssertTrue(app.navigationBars["Confirm address"].waitForExistence(timeout: 15))
        let street = app.textFields["field.street"]
        XCTAssertTrue(street.waitForExistence(timeout: 5))
        XCTAssertEqual(street.value as? String, "Sample Ave", "The picked address fills the card")
        XCTAssertEqual(app.textFields["field.civic"].value as? String, "45")
        XCTAssertFalse(app.staticTexts["Checking the address…"].exists, "A picked suggestion arrives already checked")
        let card = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        card.name = "suggest-02-confirmation"
        card.lifetime = .keepAlways
        add(card)
    }

    /// Email account through the real Auth emulator: create → "confirm your email" banner → open the
    /// emailed link → banner clears → sign out → wrong password is refused → sign in.
    func testEmailAccountAgainstEmulators() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PP_EMULATOR"] == "1", "Set TEST_RUNNER_PP_EMULATOR=1 with the emulators running")
        let app = XCUIApplication()
        app.launchArguments = ["-PPUseFirebaseEmulators", "YES", "-PPDemoMode", "NO", "-PPDisableAnimations", "YES", "-PPSignOutOnLaunch", "YES"]
        app.launch()
        func shot(_ name: String) {
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        let email = "ui-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let password = "correct-horse-1"
        /// iOS offers to save the new password in the Passwords app; decline so it doesn't cover the app.
        func dismissSavePasswordPrompt() {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.waitForExistence(timeout: 3) {
                candidate.tap()
                return
            }
        }

        XCTAssertTrue(app.buttons["continueWithEmail"].waitForExistence(timeout: 20))
        shot("email-01-sign-in-options")
        app.buttons["continueWithEmail"].tap()
        XCTAssertTrue(app.segmentedControls["emailMode"].waitForExistence(timeout: 5))
        app.segmentedControls["emailMode"].buttons["Create account"].tap()
        let emailField = app.textFields["emailField"]
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["passwordField"]
        passwordField.tap()
        passwordField.typeText(password)
        shot("email-02-create-account")
        app.buttons["emailSubmit"].tap()
        dismissSavePasswordPrompt()

        let banner = app.descendants(matching: .any)["verifyEmailBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "New email accounts are asked to confirm their address")
        shot("email-03-confirm-banner")

        try openVerificationLink(for: email)
        app.buttons["emailVerifiedRefresh"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 10), "The banner clears once the address is confirmed")

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS %@", email)).firstMatch.waitForExistence(timeout: 5), "Settings shows the signed-in email")
        app.buttons["signOut"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Sign out' AND identifier != 'signOut'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(app.buttons["continueWithEmail"].waitForExistence(timeout: 15))
        app.buttons["continueWithEmail"].tap()
        let signInEmail = app.textFields["emailField"]
        XCTAssertTrue(signInEmail.waitForExistence(timeout: 5))
        signInEmail.tap()
        signInEmail.typeText(email)
        let signInPassword = app.secureTextFields["passwordField"]
        signInPassword.tap()
        signInPassword.typeText("wrong-password")
        app.buttons["emailSubmit"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Email or password is incorrect'")).firstMatch.waitForExistence(timeout: 10))
        shot("email-04-wrong-password")
        // The form clears the password after a failed attempt.
        signInPassword.tap()
        signInPassword.typeText(password)
        app.buttons["emailSubmit"].tap()
        dismissSavePasswordPrompt()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 20), "Signed in with the right password")
        XCTAssertFalse(app.descendants(matching: .any)["verifyEmailBanner"].exists)
        shot("email-05-signed-in")
    }

    /// "Opens" the verification link the Auth emulator would have emailed.
    private func openVerificationLink(for email: String) throws {
        struct Reply: Decodable {
            struct Code: Decodable { var email: String; var requestType: String; var oobLink: String }
            var oobCodes: [Code]
        }
        let list = try XCTUnwrap(URL(string: "http://127.0.0.1:9099/emulator/v1/projects/demo-parcelpilot/oobCodes"))
        let codes = try JSONDecoder().decode(Reply.self, from: Data(contentsOf: list)).oobCodes
        let link = try XCTUnwrap(codes.last { $0.email == email && $0.requestType == "VERIFY_EMAIL" }?.oobLink, "verification email for \(email)")
        _ = try Data(contentsOf: XCTUnwrap(URL(string: link)))
    }
}
