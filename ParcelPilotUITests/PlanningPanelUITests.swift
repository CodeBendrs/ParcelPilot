import XCTest

@MainActor
final class PlanningPanelUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PPDemoMode", "YES", "-PPResetDemoData", "YES",
                               "-PPSeedDemoRoute", "YES", "-PPDisableAnimations", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["planningPanelHandle"].waitForExistence(timeout: 10))
        let toggle = app.buttons["planListToggle"]
        if toggle.label.contains("Map") { toggle.tap() }
        return app
    }

    private func expect(_ value: String, on handle: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: handle)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDraggingExpandsAndCollapsesWithoutChangingStops() {
        let app = launch()
        let handle = app.buttons["planningPanelHandle"]
        expect("Collapsed", on: handle)
        let firstStop = app.buttons["stopRow.1"].label
        let footerY = app.buttons["optimize"].frame.minY
        let collapsedY = handle.frame.minY
        XCTAssertTrue(app.descendants(matching: .any)["routeMap"].exists)
        shot("planning-panel-collapsed")

        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -240)))
        expect("Expanded", on: handle)
        XCTAssertTrue(app.buttons["planListToggle"].label.contains("Map"))
        // Keep the native map alive to retain its camera; it cannot receive touches when collapsed to zero height.
        XCTAssertFalse(app.descendants(matching: .any)["routeMap"].isHittable)
        XCTAssertLessThan(handle.frame.minY, collapsedY - 100)
        XCTAssertEqual(app.buttons["optimize"].frame.minY, footerY, accuracy: 2)
        XCTAssertEqual(app.buttons["stopRow.1"].label, firstStop)
        shot("planning-panel-expanded")

        app.collectionViews.firstMatch.swipeUp()
        expect("Expanded", on: handle)
        let expanded = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        expanded.press(forDuration: 0.15, thenDragTo: expanded.withOffset(CGVector(dx: 0, dy: 240)))
        expect("Collapsed", on: handle)
        XCTAssertTrue(app.buttons["planListToggle"].label.contains("Full list"))
        XCTAssertTrue(app.descendants(matching: .any)["routeMap"].exists)
        XCTAssertEqual(app.buttons["optimize"].frame.minY, footerY, accuracy: 2)
        shot("planning-panel-restored-map")
    }

    func testHandleTapAndListButtonShareTheSamePosition() {
        let app = launch()
        let handle = app.buttons["planningPanelHandle"]
        handle.tap()
        expect("Expanded", on: handle)
        app.buttons["planListToggle"].tap()
        expect("Collapsed", on: handle)
        app.buttons["planListToggle"].tap()
        expect("Expanded", on: handle)
        handle.tap()
        expect("Collapsed", on: handle)

        app.buttons["routeMenu"].tap()
        app.buttons["startDelivering"].firstMatch.tap()
        let currentOrder = app.buttons["confirmStartCurrentOrder"].firstMatch
        if currentOrder.waitForExistence(timeout: 1) { currentOrder.tap() }
        XCTAssertTrue(app.buttons["delivered"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["planningPanelHandle"].exists)
    }
}
