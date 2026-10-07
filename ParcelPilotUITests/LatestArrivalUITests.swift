import XCTest

@MainActor
final class LatestArrivalUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func settings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["routeMenu"].waitForExistence(timeout: 10))
        app.buttons["routeMenu"].tap()
        app.buttons["Route settings"].tap()
        XCTAssertTrue(app.textFields["routeName"].waitForExistence(timeout: 5))
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PPDemoMode", "YES", "-PPResetDemoData", "YES", "-PPSeedDemoRoute", "YES", "-PPDisableAnimations", "NO"]
        app.launch()
        settings(app)
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.isHittable { return }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    func testArrivalLimitSavesNextDayReopensAndCanBeRemoved() {
        let app = launch()
        let limit = app.switches["latestArrivalToggle"]
        reveal(limit, in: app)
        limit.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let nextDay = app.switches["Next day (after midnight)"]
        reveal(nextDay, in: app)
        nextDay.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(nextDay.value as? String, "1")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "latest-arrival-settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["saveRoute"].tap()
        settings(app)
        reveal(limit, in: app)
        XCTAssertEqual(limit.value as? String, "1")
        reveal(nextDay, in: app)
        XCTAssertEqual(nextDay.value as? String, "1")
        reveal(limit, in: app)
        limit.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        app.buttons["saveRoute"].tap()
        settings(app)
        reveal(limit, in: app)
        XCTAssertEqual(limit.value as? String, "0")
        XCTAssertFalse(nextDay.exists)
    }

    func testWarehouseIsRequiredWhenUsingAnEndArrivalLimit() {
        let app = launch()
        let returnToStart = app.switches["Return to start"]
        reveal(returnToStart, in: app)
        returnToStart.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let limit = app.switches["latestArrivalToggle"]
        reveal(limit, in: app)
        limit.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertFalse(app.buttons["saveRoute"].isEnabled)
        let end = app.buttons["routeEnd"]
        reveal(end, in: app)
        end.tap()
        let field = app.textFields["placeAddressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("123 Example St, Victoria BC V8W 1A1")
        app.buttons["placeKeyboardDone"].tap()
        app.buttons["useTypedPlace"].tap()
        XCTAssertTrue(app.buttons["saveRoute"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveRoute"].isEnabled)
    }
}
