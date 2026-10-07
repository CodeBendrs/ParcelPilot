import XCTest

/// These use the real account-bound demo SQLite backend with connectivity disabled. SDK tests
/// separately verify the same protected command envelopes against Firebase receipts/rules.
@MainActor
final class StopWorkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDown() async throws {
        await MainActor.run {
            if let app, (testRun?.failureCount ?? 0) > 0 {
                let tree = XCTAttachment(string: app.debugDescription); tree.name = "Stop work accessibility tree"; tree.lifetime = .keepAlways; add(tree)
                let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = "Stop work failure"; screen.lifetime = .keepAlways; add(screen)
            }
        }
    }

    private func launch(reset: Bool, extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-PPDemoMode", "YES", "-PPSimulateOffline", "YES", "-PPDisableAnimations", "YES",
            "-PPInitialMode", "deliver", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            + (reset ? ["-PPResetDemoData", "YES", "-PPSeedDemoRoute", "YES"] : []) + extra
        app.launch()
    }

    @discardableResult
    private func expect(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element)", file: file, line: line)
        return element
    }

    private func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let list = app.collectionViews.firstMatch
            let surface = list.exists ? list : app.scrollViews.firstMatch
            let bounds = surface.exists ? surface.frame : app.frame
            // Work moves between pending/failed/handled groups after an acknowledged action.
            // Scroll toward its current frame instead of always scrolling away from earlier rows.
            let above = element.exists && !element.frame.isEmpty && element.frame.maxY < bounds.minY + 60
            if surface.exists {
                if above { surface.swipeDown() } else { surface.swipeUp() }
            } else if above { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.exists && element.isHittable, "Unreachable \(element)", file: file, line: line)
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(element, file: file, line: line)
        element.tap()
    }

    private func openCurrentWork() { tap(expect(app.buttons["viewStopWork"].firstMatch)); expect(app.buttons["closeStopWork"]) }

    private func taskID(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let element = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'workTitle.' AND label == %@", title)).firstMatch
        reveal(element, file: file, line: line)
        return String(element.identifier.dropFirst("workTitle.".count))
    }

    private func create(_ kind: String, title: String, instructions: String = "", required: Bool = true) -> String {
        tap(app.buttons[kind == "pickup" ? "addPickup" : "addChecklist"])
        let save = expect(app.buttons["saveTask"])
        XCTAssertFalse(save.isEnabled, "A blank task must not be saved")
        let titleField = expect(app.descendants(matching: .any)["taskTitle"].firstMatch)
        titleField.tap(); titleField.typeText(title)
        if !instructions.isEmpty {
            let field = app.descendants(matching: .any)["taskInstructions"].firstMatch
            tap(field); field.typeText(instructions)
        }
        if !required { tap(app.switches["taskRequired"]); }
        XCTAssertTrue(save.isEnabled)
        save.tap()
        expect(app.buttons["closeStopWork"])
        return taskID(title)
    }

    private func state(_ id: String, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        let status = app.descendants(matching: .any)["workStatus.\(id)"].firstMatch
        reveal(status, file: file, line: line)
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains(text), "Expected \(text), got \(status.label)", file: file, line: line)
    }

    private func menuAction(_ name: String, id: String) {
        tap(app.buttons["workActions.\(id)"])
        expect(app.buttons["\(name).\(id)"].firstMatch).tap()
    }

    private func edit(_ id: String, title: String) {
        menuAction("editTask", id: id)
        let field = expect(app.textFields["taskTitle"].firstMatch)
        let old = field.value as? String ?? ""
        XCTAssertFalse(old.isEmpty, "Read the editable field value, rather than its accessibility wrapper")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + title)
        expect(app.buttons["saveTask"]).tap()
        XCTAssertEqual(taskID(title), id, "Definition editing preserves task identity")
    }

    private func openFirstStopAfterRelaunch() {
        expect(app.buttons["stopsSheet"]).tap()
        let search = expect(app.textFields["stopsSearch"])
        search.tap(); search.typeText("Shelf A1")
        tap(app.buttons["stopRow.1"])
    }

    func testMixedWorkCreationEditingAndOutcomesSurviveOfflineRelaunch() {
        launch(reset: true)
        openCurrentWork()
        let pickup = create("pickup", title: "Return tote", instructions: "Buzzer 204. Collect the blue tote.")
        let checklist = create("checklist", title: "Verify parcel count", instructions: "Compare the count at reception.")
        edit(pickup, title: "Collect return tote")
        state(pickup, contains: "Pending")
        state(checklist, contains: "Pending")

        let delivery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'completeWork.delivery_' AND label BEGINSWITH 'Delivered:'")).firstMatch
        tap(delivery)
        state(pickup, contains: "Pending")
        state(checklist, contains: "Pending")
        tap(app.buttons["completeWork.\(checklist)"])
        state(checklist, contains: "Done")
        menuAction("deferWork", id: pickup)
        state(pickup, contains: "Deferred")

        app.terminate(); launch(reset: false)
        openFirstStopAfterRelaunch()
        XCTAssertEqual(taskID("Collect return tote"), pickup)
        state(pickup, contains: "Deferred")
        // Open history so the successfully completed checklist remains inspectable on return.
        let handled = app.buttons["handledStopWork"].firstMatch
        if handled.exists { tap(handled) }
        XCTAssertEqual(taskID("Verify parcel count"), checklist)
        state(checklist, contains: "Done")
        state(pickup, contains: "Deferred")
        XCTAssertTrue(app.staticTexts["Buzzer 204. Collect the blue tote."].exists)
        tap(app.buttons["retryWork.\(pickup)"])
        state(pickup, contains: "Pending")
        menuAction("undoWork", id: pickup)
        state(pickup, contains: "Deferred")
        tap(app.buttons["retryWork.\(pickup)"])
        tap(app.buttons["completeWork.\(pickup)"])
        state(pickup, contains: "Picked up")
        state(checklist, contains: "Done")
        tap(expect(app.buttons["closeStopDetail"].firstMatch))
        XCTAssertTrue(expect(app.staticTexts["executionStatus"].firstMatch).label.contains("Route not started"), "Work never starts or finishes execution")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }

    func testFailureRetryUndoAndHistoryProtectedDeletion() {
        launch(reset: true)
        openCurrentWork()
        let pickup = create("pickup", title: "Collect returns")
        let otherPickup = create("pickup", title: "Collect mail bag")
        let optional = create("checklist", title: "Optional dock check", required: false)
        menuAction("failWork", id: pickup)
        tap(expect(app.buttons["reason.noOneHome"]))
        expect(app.buttons["saveFailure"]).tap()
        state(pickup, contains: "Failed")
        state(otherPickup, contains: "Pending")
        state(optional, contains: "Pending")
        XCTAssertFalse(app.buttons["completeWork.\(pickup)"].exists, "Failed work is unsuccessful and requires Retry")
        tap(app.buttons["retryWork.\(pickup)"])
        state(pickup, contains: "Pending")
        menuAction("undoWork", id: pickup)
        state(pickup, contains: "Failed")
        tap(app.buttons["retryWork.\(pickup)"])
        tap(app.buttons["completeWork.\(pickup)"])
        state(pickup, contains: "Picked up")
        menuAction("undoWork", id: pickup)
        state(pickup, contains: "Pending")

        menuAction("editTask", id: pickup)
        reveal(app.staticTexts["taskDeletionProtected"])
        XCTAssertFalse(app.buttons["deleteTask"].exists, "Even voided outcome history prevents destructive definition deletion")
        expect(app.buttons["cancelTaskEditor"]).tap()
        tap(app.buttons["completeWork.\(otherPickup)"])
        state(otherPickup, contains: "Picked up")
        state(pickup, contains: "Pending")
        state(optional, contains: "Pending")
    }

    func testTaskValidationCancellationAndSafePendingDeletion() {
        launch(reset: true)
        openCurrentWork()
        tap(app.buttons["addPickup"])
        let field = expect(app.descendants(matching: .any)["taskTitle"].firstMatch)
        field.tap(); field.typeText("   ")
        XCTAssertFalse(app.buttons["saveTask"].isEnabled)
        field.typeText(String(repeating: "a", count: 121))
        XCTAssertFalse(app.buttons["saveTask"].isEnabled)
        reveal(app.staticTexts["taskValidationError"])
        expect(app.buttons["cancelTaskEditor"]).tap()
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'workTitle.' AND label CONTAINS %@", String(repeating: "a", count: 121))).count, 0)

        let checklist = create("checklist", title: "Temporary check")
        menuAction("editTask", id: checklist)
        tap(app.buttons["deleteTask"])
        expect(app.buttons["confirmDeleteTask"].firstMatch).tap()
        expect(app.buttons["closeStopWork"])
        XCTAssertFalse(app.staticTexts["workTitle.\(checklist)"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'completeWork.delivery_' ")).count > 0, "Deleting independent work keeps deliveries")
    }

    func testLargeTextMixedWorkActionsRemainAccessibleWhilePaused() {
        launch(reset: true, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        expect(app.buttons["startDelivering"].firstMatch).tap()
        expect(app.buttons["confirmStartCurrentOrder"].firstMatch).tap()
        expect(app.buttons["pauseExecution"]).tap()
        openCurrentWork()
        let pickup = create("pickup", title: "Collect blue return tote")
        let checklist = create("checklist", title: "Verify reception parcel count")
        let complete = app.buttons["completeWork.\(pickup)"]
        reveal(complete)
        XCTAssertGreaterThanOrEqual(complete.frame.height, 44 - 0.001)
        XCTAssertTrue(complete.label.contains("Collect blue return tote"))
        tap(complete)
        state(pickup, contains: "Picked up")
        state(checklist, contains: "Pending")
        reveal(app.buttons["completeWork.\(checklist)"])
        XCTAssertGreaterThanOrEqual(app.buttons["completeWork.\(checklist)"].frame.height, 44 - 0.001)
        let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = "Mixed work at accessibility text size"; screen.lifetime = .keepAlways; add(screen)
        let actions = app.buttons["workActions.\(checklist)"]
        reveal(actions)
        XCTAssertGreaterThanOrEqual(actions.frame.height, 44 - 0.001)
        let add = app.buttons["addPickup"]
        reveal(add)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44 - 0.001)
        expect(app.buttons["closeStopWork"]).tap()
        XCTAssertTrue(expect(app.staticTexts["executionStatus"].firstMatch).label.contains("Route paused"))
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists, "Work UI must not request location")
    }

    func testExplicitContinuationReminderCanCancelOrBypassWithoutDiscardingPickup() {
        launch(reset: true)
        expect(app.buttons["startDelivering"].firstMatch).tap()
        expect(app.buttons["confirmStartCurrentOrder"].firstMatch).tap()
        openCurrentWork()
        let pickup = create("pickup", title: "Collect return bag before leaving")
        expect(app.buttons["closeStopWork"]).tap()
        expect(app.buttons["stopsSheet"]).tap()
        let search = expect(app.textFields["stopsSearch"])
        search.tap(); search.typeText("Shelf A2")
        expect(app.buttons["stopRow.2"]).tap()
        tap(app.buttons["deliverNext"])
        expect(app.buttons["keepCurrentStop"].firstMatch).tap()
        XCTAssertFalse(app.buttons["continueWithPendingWork"].exists)
        tap(app.buttons["deliverNext"])
        expect(app.buttons["continueWithPendingWork"].firstMatch).tap()
        XCTAssertEqual(expect(app.descendants(matching: .any)["nextStopAddress"].firstMatch).label, "45 SAMPLE AVE")
        openFirstStopAfterRelaunch()
        state(pickup, contains: "Pending")
        tap(expect(app.buttons["closeStopDetail"].firstMatch))
        XCTAssertTrue(expect(app.staticTexts["executionStatus"].firstMatch).label.contains("Route running"))
    }
}
