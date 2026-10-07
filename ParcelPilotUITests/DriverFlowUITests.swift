import XCTest

/// End-to-end driver flows in demo mode (no credentials needed). Screenshots are attached to the
/// test results and exported by scripts/capture-screenshots.sh.
final class DriverFlowUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func launch(seed: Bool = true, extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-PPDemoMode", "YES", "-PPResetDemoData", "YES", "-PPSeedDemoRoute", seed ? "YES" : "NO"] + extra
        app.launch()
    }

    func startDelivering() {
        let primary = app.buttons["startDelivering"].firstMatch
        if primary.exists && primary.isHittable { primary.tap() }
        else {
            waitFor(app.buttons["routeMenu"]).tap()
            waitFor(app.buttons["startDelivering"].firstMatch).tap()
        }
        let currentOrder = app.buttons["confirmStartCurrentOrder"].firstMatch
        if currentOrder.waitForExistence(timeout: 1) { currentOrder.tap() }
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if permission.waitForExistence(timeout: 3) { permission.tap() }
    }

    func leaveWorkspace() {
        if app.buttons["allRoutes"].exists { app.buttons["allRoutes"].tap() }
        else if app.buttons["stopsSheet"].exists {
            app.buttons["stopsSheet"].tap()
            waitFor(app.buttons["routeMenu"]).tap()
            waitFor(app.buttons["allRoutes"]).tap()
        }
    }

    func shot(_ name: String) {
        // State/control assertions come first; avoid intermediate press/sheet animation frames.
        if ProcessInfo.processInfo.environment["PP_UI_SCREEN_MATRIX"] == "1" { Thread.sleep(forTimeInterval: 0.5) }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element)", file: file, line: line)
        return element
    }

    /// List section headers are upper-cased on iOS 17/18 and not on iOS 26, so header text is matched
    /// case-insensitively.
    func header(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", text)).firstMatch
    }

    /// SwiftUI lists render rows lazily: off-screen controls don't exist until scrolled into view.
    func scrollTo(_ element: XCUIElement, in container: XCUIElement? = nil, maxSwipes: Int = 10) {
        var n = 0
        while !(element.exists && element.isHittable) && n < maxSwipes {
            let surface: XCUIElement = container ?? app
            let above = element.exists && !element.frame.isEmpty && element.frame.maxY < surface.frame.minY + 60
            if above { surface.swipeDown() } else { surface.swipeUp() }
            n += 1
        }
    }

    /// Plan → optimize (demo estimate) → apply → deliver (multi-package, undo, failure reason, skip)
    /// → retry decision → finish → history.
    func testPlanOptimizeDeliverFinish() throws {
        launch()
        waitFor(app.buttons["optimize"])
        XCTAssertTrue(app.buttons["stopRow.1"].isHittable, "A stop is visible without scrolling on the planning home screen")
        shot("01-plan-workspace")

        app.buttons["optimize"].tap()
        waitFor(app.buttons["calculate"])
        shot("02-optimize-options")
        app.buttons["calculate"].tap()

        waitFor(header("Proposed plan"), timeout: 30)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'not road travel times'")).firstMatch.exists, "Demo provenance must be shown")
        shot("03-proposal")
        let apply = app.buttons["applyPlan"]
        scrollTo(apply, in: app.collectionViews.firstMatch)
        apply.tap()

        // List status shows the applied estimate.
        expandPanel()
        waitFor(app.staticTexts["Duration"])
        shot("04-plan-optimized")

        startDelivering()
        let delivered = waitFor(app.buttons["delivered"])
        let firstAddress = app.descendants(matching: .any)["nextStopAddress"].firstMatch.label
        shot("05-deliver-next-stop")

        delivered.tap()
        if app.buttons["savePackageOutcome"].waitForExistence(timeout: 2) {
            shot("06-multi-package-outcome")
            app.buttons["savePackageOutcome"].tap()
        }
        let undo = waitFor(app.buttons["Undo"])
        shot("07-delivered-toast")
        XCTAssertNotEqual(app.descendants(matching: .any)["nextStopAddress"].firstMatch.label, firstAddress, "Next stop advances after delivery")
        undo.tap()
        XCTAssertTrue(app.descendants(matching: .any)["nextStopAddress"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.descendants(matching: .any)["nextStopAddress"].firstMatch.label, firstAddress, "Undo brings the same stop back")

        // Failed with a reason.
        app.buttons["failed"].tap()
        if app.buttons["savePackageOutcome"].waitForExistence(timeout: 2) {
            app.buttons["reason.noOneHome"].tap()
            app.buttons["savePackageOutcome"].tap()
        } else {
            waitFor(app.buttons["reason.noOneHome"]).tap()
            shot("08-failure-reason")
            app.buttons["saveFailure"].tap()
        }
        // Skip the next one, then retry the failed package.
        app.buttons["skip"].tap()
        waitFor(app.buttons["stopsSheet"]).tap()
        waitFor(app.staticTexts["Needs a decision"])
        let retry = app.buttons["Retry later"].firstMatch
        scrollTo(retry, in: app.collectionViews.firstMatch)
        shot("09-needs-decision")
        retry.tap()

        // Finish early and find the route in History.
        let finishEarly = app.buttons["Finish route…"]
        scrollTo(finishEarly, in: app.collectionViews.firstMatch)
        finishEarly.tap()
        waitFor(app.buttons["Finish route"]).tap()
        leaveWorkspace()
        app.tabBars.buttons["History"].tap()
        waitFor(app.buttons["historyRow"]).tap()
        waitFor(header("Results"))
        let distance = header("Distance")
        scrollTo(distance, in: app.collectionViews.firstMatch)
        XCTAssertTrue(distance.exists, "History summary shows the distance section with its source")
        shot("10-history-summary")
    }

    /// Manual address entry: parse → confirmation card (three separate signals) → add.
    func testManualAddressEntry() throws {
        launch()
        waitFor(app.buttons["addStops"]).tap()
        waitFor(app.buttons["addManual"]).tap()
        let field = waitFor(app.textFields["manualAddressField"])
        field.tap()
        field.typeText("Unit 12, 400 Placeholder Ave, Victoria BC V8W 2C2")
        app.buttons["manualContinue"].tap()
        waitFor(app.staticTexts["Address completeness"], timeout: 10)
        XCTAssertTrue(app.staticTexts["Map match"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Demo location — not verified"].exists, "Synthetic results are never presented as verified")
        shot("11-manual-confirmation")
        let add = app.buttons["addToRoute"]
        scrollTo(add, in: app.collectionViews.firstMatch)
        add.tap()
        waitFor(app.buttons["optimize"])
        let addedStop = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] '400 Placeholder Ave'")).firstMatch
        scrollTo(addedStop, in: app.collectionViews.firstMatch)
        XCTAssertTrue(addedStop.exists, "The new address must actually be on the route")
    }

    /// Paste import with a duplicate and an invalid row.
    func testPasteImport() throws {
        launch(seed: false)
        waitFor(app.buttons["newRoute"]).tap()
        waitFor(app.buttons["saveRoute"]).tap()
        waitFor(app.buttons["addStops"]).tap()
        waitFor(app.buttons["addPaste"]).tap()
        let editor = waitFor(app.textViews["pasteField"])
        editor.tap()
        editor.typeText("123 Example St, Victoria BC V8W 1A1\n45 Sample Ave, Victoria BC V8V 2B2\n123 EXAMPLE ST, VICTORIA BC V8W1A1\nnot an address\n")
        app.buttons["pasteReview"].tap()
        waitFor(app.staticTexts["Row 4"])
        shot("12-paste-review")
        let importButton = app.buttons["importNow"]
        scrollTo(importButton, in: app.collectionViews.firstMatch)
        importButton.tap()
        waitFor(app.buttons["optimize"], timeout: 15)
        shot("13-after-import")
    }

    /// Simulator has no camera: the scan tab must offer import / typing alternatives.
    func testScanFallbackWithoutCamera() throws {
        launch(extra: ["-PPInitialTab", "scan"])
        XCTAssertFalse(app.buttons["allowCamera"].exists, "The simulator must not offer permission for nonexistent camera hardware")
        XCTAssertTrue(app.buttons["typeAddress"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["importPhoto"].exists)
        XCTAssertFalse(app.buttons["shutter"].isEnabled, "No enabled shutter without a camera")
        shot("15-scan-tab")
        app.descendants(matching: .any)["batchToggle"].firstMatch.tap()
        shot("16-scan-batch-mode")
    }

    func testSettingsAndPrivacy() throws {
        launch()
        leaveWorkspace()
        app.tabBars.buttons["Settings"].tap()
        waitFor(app.staticTexts["Navigation app"])
        shot("17-settings")
        app.staticTexts["What ParcelPilot stores"].tap()
        waitFor(header("Never stored or uploaded"))
        shot("18-privacy")
    }

    func testLargeTextDeliverView() throws {
        launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        startDelivering()
        waitFor(app.buttons["delivered"])
        XCTAssertTrue(app.buttons["delivered"].isHittable, "Delivered stays reachable at large text sizes")
        XCTAssertGreaterThanOrEqual(app.buttons["delivered"].frame.height, 72)
        XCTAssertTrue(app.staticTexts["actionDestination"].label.contains("Unit 204"))
        shot("19-deliver-accessibility-large-text")
        let address = app.descendants(matching: .any)["nextStopAddress"].firstMatch.label
        waitFor(app.buttons["showMap"]).tap()
        XCTAssertTrue(waitFor(app.descendants(matching: .any)["routeMap"]).exists)
        shot("19-full-screen-map-accessibility")
        waitFor(app.buttons["Close"]).tap()
        XCTAssertEqual(waitFor(app.descendants(matching: .any)["nextStopAddress"].firstMatch).label, address)
        XCTAssertTrue(app.buttons["delivered"].isHittable)
    }
    func expandPanel() {
        let toggle = waitFor(app.buttons["planListToggle"])
        if toggle.label.contains("Full list") { toggle.tap() }
    }

    func testPanelSwipesStopRemovalUndoAndNextStop() throws {
        launch()
        waitFor(app.buttons["stopRow.1"])
        expandPanel()
        shot("20-expanded-stop-list")
        let first = app.buttons["stopRow.1"]
        let original = first.label
        first.swipeLeft()
        waitFor(app.buttons["Remove"]).tap()
        waitFor(app.buttons["Undo"]).tap()
        XCTAssertEqual(app.buttons["stopRow.1"].label, original, "Removal Undo restores the address, unit and packages")
        let second = app.buttons["stopRow.2"]
        scrollTo(second, in: app.collectionViews.firstMatch)
        second.swipeRight()
        waitFor(app.buttons["Deliver next"]).tap()
        startDelivering()
        XCTAssertEqual(waitFor(app.descendants(matching: .any)["nextStopAddress"].firstMatch).label, "45 SAMPLE AVE")
        shot("21-selected-next-stop")
        XCTAssertFalse(app.buttons["panelHandle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["nextStopAddress"].firstMatch.isHittable)
        // CGRect subtraction can report 43.99999999999997 for an exact 44-point frame.
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any)["nextStopAddress"].firstMatch.frame.height, 44 - 0.001)
        XCTAssertTrue(app.buttons["delivered"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["delivered"].frame.height, 58)
        shot("22-fixed-delivery-layout")
    }

    func testReorderStops() throws {
        launch()
        expandPanel()
        let firstLabel = waitFor(app.buttons["stopRow.1"]).label
        let second = app.buttons["stopRow.2"]
        waitFor(app.buttons["reorder"]).tap()
        // The native list exposes reorder handles during editing.
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder '"))
        XCTAssertGreaterThanOrEqual(handles.count, 3, app.debugDescription)
        shot("23-before-reordering")
        XCTAssertTrue(handles.element(boundBy: 1).isHittable)
        let target = handles.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: 20))
        handles.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: target)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", firstLabel), object: app.buttons["stopRow.1"])
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed, "Dragging the handle changes the actual order")
        app.buttons["reorder"].tap()
        XCTAssertNotEqual(app.buttons["stopRow.1"].label, firstLabel)
        XCTAssertTrue(second.exists)
        shot("23-reordered-stops")
    }

    func testFindPackageOpensDetailsAndCancelPackageAdd() throws {
        launch()
        waitFor(app.buttons["findPackage"]).tap()
        let search = waitFor(app.searchFields.firstMatch)
        search.tap()
        search.typeText("Shelf A1")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS 'In vehicle: Shelf A1'")).firstMatch
        waitFor(result).tap()
        waitFor(app.navigationBars["Stop 1"])
        scrollTo(header("Packages (2)"), in: app.collectionViews.firstMatch)
        XCTAssertTrue(header("Packages (2)").exists)
        shot("24-package-search-details")
        let add = app.buttons["Add another package"]
        scrollTo(add, in: app.collectionViews.firstMatch)
        add.tap()
        waitFor(app.buttons["savePackage"])
        app.buttons["Cancel"].tap()
        scrollTo(header("Packages (2)"), in: app.collectionViews.firstMatch)
        XCTAssertTrue(header("Packages (2)").exists, "Cancel must not create a package")
        scrollTo(app.buttons["Add another package"], in: app.collectionViews.firstMatch)
        app.buttons["Add another package"].tap()
        waitFor(app.buttons["savePackage"]).tap()
        scrollTo(header("Packages (3)"), in: app.collectionViews.firstMatch)
        XCTAssertTrue(header("Packages (3)").exists)
        let packageID = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'packageRow.'")).firstMatch.identifier
        let package = app.buttons[packageID]
        package.tap()
        waitFor(app.buttons["Front"]).tap()
        app.buttons["Cancel"].tap()
        XCTAssertFalse(package.label.contains("Front"), "Cancel discards package edits")
        package.tap()
        waitFor(app.buttons["Front"]).tap()
        app.buttons["savePackage"].tap()
        XCTAssertTrue(package.label.contains("Front"), "Saving updates the vehicle location")
        package.swipeLeft()
        waitFor(app.buttons["Remove"]).tap()
        XCTAssertTrue(header("Packages (2)").exists)
        waitFor(app.buttons["Undo remove package"]).tap()
        XCTAssertTrue(header("Packages (3)").exists)
        XCTAssertTrue(package.label.contains("Front"))
        shot("25-added-package")
        app.buttons["Done"].tap()
    }

    func testRouteRenameDuplicateArchiveReopen() throws {
        launch()
        waitFor(app.buttons["routeMenu"]).tap()
        waitFor(app.buttons["Rename"]).tap()
        let name = waitFor(app.alerts.textFields.firstMatch)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count + 3))
        name.typeText("Morning deliveries")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Morning deliveries"].waitForExistence(timeout: 5))
        app.buttons["routeMenu"].tap()
        waitFor(app.buttons["Duplicate"]).tap()
        XCTAssertTrue(app.staticTexts["Morning deliveries copy"].waitForExistence(timeout: 10))
        app.buttons["routeMenu"].tap()
        waitFor(app.buttons["Archive"]).tap()
        waitFor(app.buttons["newRoute"])
        leaveWorkspace()
        app.tabBars.buttons["History"].tap()
        waitFor(app.buttons["historyRow"]).tap()
        let reopen = app.buttons["Reopen route"]
        scrollTo(reopen, in: app.collectionViews.firstMatch)
        reopen.tap()
        waitFor(app.buttons["optimize"])
        XCTAssertTrue(app.buttons["routeMenu"].isHittable, "Reopening returns to the route workspace")
        XCTAssertFalse(app.tabBars.buttons["Route"].exists, "The workspace hides the tab bar")
        shot("26-reopened-route")
    }

    func testPartialDeliveryFailureCancelAndExcludeUndo() throws {
        launch()
        startDelivering()
        let address = waitFor(app.descendants(matching: .any)["nextStopAddress"].firstMatch).label
        app.buttons["failed"].tap()
        XCTAssertFalse(waitFor(app.buttons["saveFailure"]).isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["nextStopAddress"].firstMatch.label, address)
        waitFor(app.buttons["packageToggle.1"]).tap()
        XCTAssertTrue(app.buttons["delivered"].label.contains("1 of 2"))
        app.buttons["delivered"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["nextStopAddress"].firstMatch.label, address, "The other package keeps this stop active")
        app.buttons["failed"].tap()
        XCTAssertFalse(waitFor(app.buttons["saveFailure"]).isEnabled)
        app.buttons["reason.noOneHome"].tap()
        app.buttons["saveFailure"].tap()
        waitFor(app.buttons["stopsSheet"]).tap()
        let exclude = app.buttons["Exclude"].firstMatch
        scrollTo(exclude, in: app.collectionViews.firstMatch)
        exclude.tap()
        waitFor(app.buttons["Undo"]).tap()
        XCTAssertTrue(app.buttons["Retry later"].firstMatch.exists)
        shot("27-partial-delivery-decisions")
    }

    func testScanReviewTypingPhotoAndCSVFallbacks() throws {
        launch(extra: ["-PPInitialTab", "scan"])
        waitFor(app.buttons["reviewQueue"]).tap()
        waitFor(app.staticTexts["Nothing to review"])
        shot("28-empty-review-queue")
        app.buttons["Done"].tap()
        app.buttons["typeAddress"].tap()
        waitFor(app.textFields["manualAddressField"])
        app.buttons["Cancel"].tap()
        app.buttons["importPhoto"].tap()
        // The system photo picker must open and remain dismissible.
        waitFor(app.buttons["Cancel"]).tap()
        app.tabBars.buttons["Route"].tap()
        waitFor(app.buttons["addStops"]).tap()
        waitFor(app.buttons["addCSV"]).tap()
        waitFor(app.buttons["Cancel"]).tap()
        shot("29-csv-picker-cancelled")
        app.buttons["Cancel"].tap()
    }

    func testOfflineDeliveryPersistsAfterRelaunch() throws {
        launch(extra: ["-PPSimulateOffline", "YES"])
        startDelivering()
        waitFor(app.buttons["skip"]).tap()
        let next = app.descendants(matching: .any)["nextStopAddress"].firstMatch.label
        app.terminate()
        app.launchArguments = ["-PPDemoMode", "YES", "-PPSimulateOffline", "YES"]
        app.launch()
        waitFor(app.buttons["delivered"])
        XCTAssertEqual(app.descendants(matching: .any)["nextStopAddress"].firstMatch.label, next)
        waitFor(app.buttons["stopsSheet"]).tap()
        let retry = app.buttons["Retry later"].firstMatch
        scrollTo(retry, in: app.collectionViews.firstMatch)
        XCTAssertTrue(retry.exists)
        shot("30-offline-relaunch")
    }

    func testStopAddressPinAndDeliveryWindowEditing() throws {
        launch()
        waitFor(app.buttons["stopRow.1"]).tap()
        let editAddress = app.buttons["editStopAddress"]
        scrollTo(editAddress, in: app.collectionViews.firstMatch)
        waitFor(editAddress).tap()
        waitFor(app.textFields["Number"]).tap()
        app.textFields["Number"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "321")
        waitFor(app.buttons["Check address"]).tap()
        let save = app.navigationBars["Edit address"].buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        waitFor(app.buttons["placeStopPin"]).tap()
        waitFor(app.buttons["Use this location"]).tap()
        XCTAssertTrue(waitFor(app.buttons["placeStopPin"]).label.contains("Move pin"), "The saved driver pin is shown as movable")
        let detailNavigate = app.buttons["Navigate"]
        scrollTo(detailNavigate, in: app.collectionViews.firstMatch)
        detailNavigate.tap()
        waitFor(app.buttons["Apple Maps"])
        XCTAssertTrue(app.buttons["Google Maps"].exists, "Ask each time works from stop details")
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.navigationBars["Stop 1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        for _ in 0..<4 { app.collectionViews.firstMatch.swipeDown() }
        let window = app.buttons["deliveryTimePicker"]
        scrollTo(window, in: app.collectionViews.firstMatch)
        window.tap()
        waitFor(app.buttons["Prefer to arrive by"]).tap()
        let saveWindow = app.buttons["saveDeliveryTime"]
        scrollTo(saveWindow, in: app.collectionViews.firstMatch)
        saveWindow.tap()
        shot("31-stop-pin-and-time-window")
        app.buttons["Done"].tap()
        startDelivering()
        XCTAssertEqual(waitFor(app.descendants(matching: .any)["nextStopAddress"].firstMatch).label, "321 EXAMPLE ST")
    }

    func testNavigationReturnDoesNotDeliver() throws {
        launch()
        startDelivering()
        let address = waitFor(app.descendants(matching: .any)["nextStopAddress"].firstMatch).label
        app.buttons["navigate"].tap()
        waitFor(app.buttons["Apple Maps"]).tap()
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        XCTAssertTrue(maps.wait(for: .runningForeground, timeout: 15))
        app.activate()
        waitFor(app.descendants(matching: .any)["returnBanner"].firstMatch)
        XCTAssertEqual(app.descendants(matching: .any)["nextStopAddress"].firstMatch.label, address)
        XCTAssertTrue(app.buttons["delivered"].isEnabled)
        XCTAssertTrue(app.buttons["pauseExecution"].exists, "Navigation handoff and return keep the explicitly started session active")
        shot("32-back-from-navigation")
    }

    func testOptimizeKeepCurrentOrderAndRouteSettings() throws {
        launch()
        let first = waitFor(app.buttons["stopRow.1"]).label
        app.buttons["optimize"].tap()
        waitFor(app.buttons["calculate"]).tap()
        let keep = waitFor(app.buttons["keepCurrentOrder"], timeout: 20)
        shot("atlas-optimize-preview")
        scrollTo(keep, in: app.collectionViews.firstMatch)
        keep.tap()
        XCTAssertEqual(app.buttons["stopRow.1"].label, first)
        XCTAssertTrue(app.buttons["startDelivering"].isEnabled)
        app.buttons["routeMenu"].tap()
        waitFor(app.buttons["Route settings"]).tap()
        waitFor(app.textFields["routeName"])
        let returnToStart = app.switches["Return to start"]
        scrollTo(returnToStart, in: app.collectionViews.firstMatch)
        returnToStart.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(returnToStart.value as? String, "0")
        let end = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ends at the last stop'")).firstMatch
        scrollTo(end, in: app.collectionViews.firstMatch)
        XCTAssertTrue(end.exists)
        app.buttons["saveRoute"].tap()
        waitFor(app.buttons["optimize"])
        shot("33-route-settings-saved")
    }

    func testMapSelectionPanAndZoom() throws {
        launch()
        startDelivering()
        let address = waitFor(app.descendants(matching: .any)["nextStopAddress"].firstMatch).label
        let map = waitFor(app.descendants(matching: .any)["routeMap"].firstMatch)
        map.pinch(withScale: 1.5, velocity: 1)
        map.swipeLeft()
        waitFor(app.buttons["stopStrip.3"]).tap()
        waitFor(app.buttons["Details"]).tap()
        waitFor(app.navigationBars["Stop 3"])
        app.buttons["Done"].tap()
        XCTAssertEqual(waitFor(app.descendants(matching: .any)["nextStopAddress"].firstMatch).label, address, "Inspecting a strip stop never changes the next delivery")
        shot("34-map-pan-and-zoom")
    }

    /// Seed the simulator photo library with fixtures/labels/e1_victoria_unit204.png using simctl
    /// addmedia, then run with TEST_RUNNER_PP_UI_PHOTO_FIXTURE=1. Ordinary runs skip this dependency.
    func testImportedLabelPhotoThroughRecognitionAndConfirmation() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PP_UI_PHOTO_FIXTURE"] == "1", "Requires the synthetic label fixture in the simulator photo library")
        launch(extra: ["-PPInitialTab", "scan"])
        waitFor(app.buttons["importPhoto"]).tap()
        shot("35-label-photo-picker")
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), app.debugDescription)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitFor(app.navigationBars["Confirm label"], timeout: 30)
        XCTAssertTrue(app.staticTexts["Text recognition"].exists)
        XCTAssertTrue(app.buttons["addToRoute"].isHittable, "The confirmation action stays visible before scrolling")
        XCTAssertLessThanOrEqual(app.buttons["addToRoute"].frame.maxY, app.frame.maxY, "The confirmation action is inside the visible screen")
        shot("36-imported-label-confirmation")
        app.buttons["addToRoute"].tap()
        waitFor(app.buttons["reviewQueue"])
        app.tabBars.buttons["Route"].tap()
        expandPanel()
        app.buttons["stopRow.1"].tap()
        XCTAssertTrue(header("Packages (3)").waitForExistence(timeout: 5), "A scanned label at the existing unit adds a package to that stop")
        shot("37-imported-label-package")
    }

    /// Requires ParcelPilot-Audit.csv in the simulator's On My iPhone Files storage.
    func testProofOfDeliveryPhotoImportAndRemove() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PP_UI_PHOTO_FIXTURE"] == "1", "Requires the synthetic label fixture in Photos")
        launch()
        waitFor(app.buttons["stopRow.1"]).tap()
        let addPhoto = app.buttons["Add photo"]
        scrollTo(addPhoto, in: app.collectionViews.firstMatch)
        addPhoto.tap()
        waitFor(app.buttons["Choose from library"]).tap()
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
        waitFor(photo).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo ·'")).firstMatch
        waitFor(saved)
        scrollTo(saved, in: app.collectionViews.firstMatch)
        saved.tap()
        waitFor(app.navigationBars["Photo"])
        waitFor(app.images["deliveryPhoto"])
        shot("42-proof-of-delivery-photo")
        app.buttons["Delete"].tap()
        waitFor(app.buttons["Add photo"])
        XCTAssertFalse(saved.exists)
        shot("43-photo-removed")
    }

    /// Requires ParcelPilot-Audit.csv in the simulator's On My iPhone Files storage.
    func testCSVFileMappingReviewAndImport() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PP_UI_CSV_FIXTURE"] == "1", "Requires the synthetic CSV fixture in Files")
        launch(seed: false)
        waitFor(app.buttons["newRoute"]).tap()
        waitFor(app.buttons["saveRoute"]).tap()
        waitFor(app.buttons["addStops"]).tap()
        waitFor(app.buttons["addCSV"]).tap()
        waitFor(app.tabBars.buttons["Browse"]).tap()
        let onPhone = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'On My iPhone'")).firstMatch
        waitFor(onPhone).tap()
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'ParcelPilot-Audit'")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        shot("38-csv-file-picker")
        file.tap()
        waitFor(app.buttons["Review rows"])
        XCTAssertTrue(app.staticTexts["Full address"].exists)
        shot("39-csv-column-mapping")
        app.buttons["Review rows"].tap()
        waitFor(app.staticTexts["Row 4"])
        shot("40-csv-review-errors")
        let importNow = app.buttons["importNow"]
        scrollTo(importNow, in: app.collectionViews.firstMatch)
        XCTAssertTrue(importNow.label.contains("2"), "Only the two valid CSV rows are selected")
        importNow.tap()
        waitFor(app.buttons["optimize"])
        expandPanel()
        XCTAssertTrue(app.buttons["stopRow.1"].label.uppercased().contains("400 PLACEHOLDER AVE"), app.buttons["stopRow.1"].label)
        XCTAssertTrue(app.buttons["stopRow.2"].label.uppercased().contains("45 SAMPLE AVE"), app.buttons["stopRow.2"].label)
        shot("41-csv-imported-stops")
    }


    func testSkipUndoAndRetryUndo() throws {
        launch()
        startDelivering()
        let first = waitFor(app.descendants(matching: .any)["nextStopAddress"].firstMatch).label
        app.buttons["skip"].tap()
        XCTAssertNotEqual(waitFor(app.descendants(matching: .any)["nextStopAddress"].firstMatch).label, first)
        waitFor(app.buttons["Undo"]).tap()
        XCTAssertEqual(waitFor(app.descendants(matching: .any)["nextStopAddress"].firstMatch).label, first)
        app.buttons["skip"].tap()
        waitFor(app.buttons["stopsSheet"]).tap()
        waitFor(app.buttons["Retry later"].firstMatch).tap()
        waitFor(app.buttons["Undo"]).tap()
        XCTAssertTrue(app.buttons["Retry later"].firstMatch.exists)
    }

    /// Used by capture-screenshots.sh: wait for real controls instead of photographing a launch screen.
    func testPrimaryScreensForScreenshotAudit() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PP_UI_SCREEN_MATRIX"] == "1", "Screenshot audit only")
        launch(extra: ["-PPDisableAnimations", "YES"])
        waitFor(app.buttons["optimize"])
        let toggle = waitFor(app.buttons["planListToggle"])
        if toggle.label.contains("Map") { toggle.tap() }
        shot("matrix-plan")
        expandPanel()
        shot("matrix-plan-list")
        app.buttons["optimize"].tap()
        scrollTo(app.buttons["calculate"], in: app.collectionViews.firstMatch)
        waitFor(app.buttons["calculate"]).tap()
        waitFor(app.buttons["applyPlan"], timeout: 30)
        shot("matrix-optimize")
        app.buttons["keepCurrentOrder"].tap()
        XCTAssertTrue(app.buttons["startDelivering"].isEnabled)
        startDelivering()
        waitFor(app.buttons["delivered"])
        let locationPermission = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        XCTAssertFalse(locationPermission.exists, "System permission prompts are not accepted as design screenshots")
        let destination = app.descendants(matching: .any)["nextStopAddress"].firstMatch
        if app.buttons["showMap"].exists {
            XCTAssertTrue(app.staticTexts["actionDestination"].isHittable)
        } else {
            XCTAssertTrue(destination.isHittable)
        }
        shot("matrix-deliver")
        waitFor(app.buttons["packageToggle.1"]).tap()
        app.buttons["delivered"].tap()
        XCTAssertTrue(waitFor(app.buttons["packageToggle.0"]).exists, "The unselected package remains actionable")
        shot("matrix-partial")
        waitFor(app.buttons["stopsSheet"]).tap()
        XCTAssertTrue(waitFor(app.textFields["stopsSearch"]).isHittable)
        shot("matrix-stops")
        app.buttons["Done"].tap()
        launch(extra: ["-PPInitialTab", "scan", "-PPDisableAnimations", "YES"])
        waitFor(app.buttons["typeAddress"])
        shot("matrix-scan")
        app.buttons["typeAddress"].tap()
        waitFor(app.textFields["manualAddressField"]).tap()
        app.textFields["manualAddressField"].typeText("Example St, Victoria BC V8W 1B2")
        if app.buttons["manualKeyboardDone"].waitForExistence(timeout: 2) { app.buttons["manualKeyboardDone"].tap() }
        scrollTo(app.buttons["manualContinue"], in: app.collectionViews.firstMatch)
        waitFor(app.buttons["manualContinue"]).tap()
        waitFor(app.buttons["addToRoute"])
        shot("matrix-address-review")
        app.navigationBars["Review address"].buttons["Cancel"].tap()
        waitFor(app.navigationBars["Search an address"].buttons["Cancel"]).tap()
        app.tabBars.buttons["History"].tap()
        waitFor(app.staticTexts["No finished routes"])
        shot("matrix-history")
        app.tabBars.buttons["Settings"].tap()
        waitFor(app.staticTexts["Navigation app"])
        shot("matrix-settings")
    }

}
