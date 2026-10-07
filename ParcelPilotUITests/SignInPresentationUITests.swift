import XCTest

/// Presentation checks use the existing emulator-only signed-out fixture, without submitting accounts.
@MainActor
final class SignInPresentationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PPUseFirebaseEmulators", "YES", "-PPDemoMode", "NO",
                               "-PPDisableAnimations", "YES", "-PPSignOutOnLaunch", "YES"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["continueWithEmail"].waitForExistence(timeout: 15))
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    func testEmailSheetAndAccountModesRemainReachable() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Ready for your\nnext route?"].exists)
        XCTAssertTrue(app.buttons["continueWithGoogle"].exists)
        XCTAssertFalse(app.buttons["continueWithGoogle"].isEnabled, "The emulator has no Google client ID")
        XCTAssertFalse(app.buttons["Try demo mode"].exists)
        let email = app.buttons["continueWithEmail"]
        reveal(email, in: app)
        email.tap()
        XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["emailSubmit"].isEnabled)
        XCTAssertFalse(app.buttons["forgotPassword"].isEnabled)
        app.buttons["Create account"].firstMatch.tap()
        XCTAssertTrue(app.secureTextFields["passwordField"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(email.waitForExistence(timeout: 5))
    }

    func testLargestTextCanScrollToEmailAndPrivacyCopy() {
        let app = launch(largeText: true)
        let email = app.buttons["continueWithEmail"]
        reveal(email, in: app)
        email.tap()
        XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        let privacy = app.staticTexts["Delete your account and data anytime\nin Settings."]
        reveal(privacy, in: app)
        XCTAssertTrue(privacy.isHittable)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "sign-in-largest-text"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
