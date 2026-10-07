import XCTest

/// Driver intent is independent of screen mode, work outcomes, scene phase, and connectivity.
/// Real relaunches exercise the protected SQLite session rather than an in-memory view state.
@MainActor
final class ExecutionSessionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(reset: Bool, extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-PPDemoMode", "YES", "-PPSimulateOffline", "YES", "-PPDisableAnimations", "YES"]
            + (reset ? ["-PPResetDemoData", "YES", "-PPSeedDemoRoute", "YES"] : []) + extra
        app.launch()
    }

    @discardableResult
    private func expect(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element)", file: file, line: line)
        return element
    }

    private func status(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = expect(app.staticTexts["executionStatus"].firstMatch, file: file, line: line)
        XCTAssertTrue(element.label.contains(label), "Expected \(label), got \(element.label)", file: file, line: line)
    }

    private func startCurrentOrder() {
        expect(app.buttons["startDelivering"].firstMatch).tap()
        expect(app.buttons["confirmStartCurrentOrder"].firstMatch).tap()
        status("Route running")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists,
                       "Explicit Start must not request location permission")
    }

    private func relaunch() {
        app.terminate()
        launch(reset: false)
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    func testStartPauseResumeFinishSurviveOfflineRelaunch() {
        launch(reset: true)
        startCurrentOrder()
        relaunch()
        status("Route running")
        expect(app.buttons["pauseExecution"]).tap()
        status("Route paused")
        relaunch()
        status("Route paused")
        expect(app.buttons["resumeExecution"].firstMatch).tap()
        status("Route running")
        relaunch()
        status("Route running")

        // Deferred work remains distinct from pending and from successful work at close-out.
        expect(app.buttons["skip"]).tap()
        expect(app.buttons["stopsSheet"]).tap()
        let finish = app.buttons["finishRoute"]
        scrollTo(finish)
        finish.tap()
        expect(app.navigationBars["Finish this route?"])
        XCTAssertTrue(app.staticTexts["Pending"].exists)
        XCTAssertTrue(app.staticTexts["Deferred"].exists)
        XCTAssertTrue(app.staticTexts["Failed (unsuccessful)"].exists)
        let unfinished = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Unfinished required work")).firstMatch
        scrollTo(unfinished)
        XCTAssertTrue(unfinished.exists)
        expect(app.buttons["confirmFinishRoute"]).tap()
        expect(app.buttons["newRoute"])

        relaunch()
        expect(app.buttons["newRoute"])
        XCTAssertFalse(app.buttons["returnToExecutionRoute"].exists, "Finished execution stays off after relaunch")
        app.tabBars.buttons["History"].tap()
        expect(app.buttons["historyRow"]).tap()
        let reopen = app.buttons["reopenRoute"]
        scrollTo(reopen)
        reopen.tap()
        expect(app.buttons["startDelivering"].firstMatch)
        XCTAssertFalse(app.buttons["pauseExecution"].exists, "Reopening must not resurrect execution")
    }

    func testOutcomeAndScreenModeDoNotStartAndForegroundDoesNotResume() {
        launch(reset: true, extra: ["-PPInitialMode", "deliver"])
        status("Route not started")
        expect(app.buttons["delivered"]).tap()
        status("Route not started")
        startCurrentOrder()
        expect(app.buttons["pauseExecution"]).tap()
        status("Route paused")

        XCUIDevice.shared.press(.home)
        app.activate()
        status("Route paused")
        XCTAssertTrue(app.buttons["delivered"].isEnabled, "Pause keeps explicit work recording available")
        expect(app.buttons["resumeExecution"].firstMatch).tap()
        status("Route running")
        XCUIDevice.shared.press(.home)
        app.activate()
        status("Route running")
    }

    func testBrowsingAnotherRouteDoesNotSwitchExecution() {
        launch(reset: true)
        startCurrentOrder()
        expect(app.buttons["stopsSheet"]).tap()
        expect(app.buttons["routeMenu"]).tap()
        expect(app.buttons["allRoutes"]).tap()
        expect(app.buttons["returnToExecutionRoute"])
        expect(app.buttons["newRoute"]).tap()
        expect(app.buttons["saveRoute"]).tap()
        expect(app.buttons["returnToExecutionRoute"].firstMatch).tap()
        status("Route running")
        XCTAssertTrue(app.buttons["pauseExecution"].exists)
    }
}
