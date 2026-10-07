import XCTest

@MainActor
final class PlaceEntryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PPDemoMode", "YES", "-PPResetDemoData", "YES",
                               "-PPSeedDemoRoute", "YES", "-PPDisableAnimations", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["routeMenu"].waitForExistence(timeout: 10))
        app.buttons["routeMenu"].tap()
        app.buttons["Route settings"].tap()
        XCTAssertTrue(app.textFields["routeName"].waitForExistence(timeout: 5))
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.isHittable { return }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    func testStartAddressAcceptsTypingAndPersistsAfterSaving() {
        let app = launchSettings()
        let start = app.buttons["routeStart"]
        reveal(start, in: app)
        start.tap()
        let field = app.textFields["placeAddressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["placeKeyboardDone"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["placeSearch"].isEnabled)

        // No tap first: opening the nested sheet should already focus its address field.
        let address = "123 Example St, Victoria BC V8W 1A1"
        field.typeText(address)
        XCTAssertEqual(field.value as? String, address)
        XCTAssertTrue(app.buttons["placeSearch"].isEnabled)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "start-location-typing"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["placeKeyboardDone"].tap()
        field.tap()
        field.typeText(" Canada")
        let editedAddress = field.value as? String ?? ""
        XCTAssertTrue(editedAddress.contains("Canada"))
        XCTAssertEqual(editedAddress.count, address.count + " Canada".count)
        app.buttons["placeKeyboardDone"].tap()
        app.buttons["useTypedPlace"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.label.contains(editedAddress))
        app.buttons["saveRoute"].tap()
        XCTAssertTrue(app.buttons["routeMenu"].waitForExistence(timeout: 5))
        app.buttons["routeMenu"].tap()
        app.buttons["Route settings"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.label.contains(editedAddress))
    }

    func testEndAddressAcceptsTypingAfterCancellingAndReopening() {
        let app = launchSettings()
        let returnToStart = app.switches["Return to start"]
        reveal(returnToStart, in: app)
        returnToStart.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let end = app.buttons["routeEnd"]
        reveal(end, in: app)
        end.tap()
        let field = app.textFields["placeAddressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Discard this")
        app.navigationBars["End location"].buttons["Cancel"].tap()
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        XCTAssertFalse(end.label.contains("Discard this"))
        end.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let address = "456 Example Ave, Victoria BC V8W 1A1"
        field.typeText(address)
        XCTAssertEqual(field.value as? String, address)
        app.buttons["placeKeyboardDone"].tap()
        app.buttons["useTypedPlace"].tap()
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        XCTAssertTrue(end.label.contains(address))
    }
}
