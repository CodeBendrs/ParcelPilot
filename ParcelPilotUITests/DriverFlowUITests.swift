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

    func shot(_ name: String) {
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
            (container ?? app).swipeUp()
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

        // Plan summary now shows the applied estimate.
        waitFor(app.staticTexts["Duration"])
        shot("04-plan-optimized")

        app.segmentedControls["workspaceMode"].buttons["Deliver"].tap()
        let delivered = waitFor(app.buttons["delivered"])
        let firstAddress = app.staticTexts["nextStopAddress"].label
        shot("05-deliver-next-stop")

        delivered.tap()
        if app.buttons["savePackageOutcome"].waitForExistence(timeout: 2) {
            shot("06-multi-package-outcome")
            app.buttons["savePackageOutcome"].tap()
        }
        let undo = waitFor(app.buttons["Undo"])
        shot("07-delivered-toast")
        XCTAssertNotEqual(app.staticTexts["nextStopAddress"].label, firstAddress, "Next stop advances after delivery")
        undo.tap()
        XCTAssertTrue(app.staticTexts["nextStopAddress"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["nextStopAddress"].label, firstAddress, "Undo brings the same stop back")

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
        waitFor(app.staticTexts["Needs a decision"])

        // Skip the next one, then retry the failed package.
        app.buttons["skip"].tap()
        let retry = app.buttons["Retry later"].firstMatch
        scrollTo(retry, in: app.scrollViews.firstMatch)
        shot("09-needs-decision")
        retry.tap()

        // Finish early and find the route in History.
        let finishEarly = app.buttons["Finish early…"]
        scrollTo(finishEarly, in: app.scrollViews.firstMatch)
        finishEarly.tap()
        waitFor(app.buttons["Finish route"]).tap()
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
        launch()
        app.tabBars.buttons["Scan"].tap()
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
        app.tabBars.buttons["Settings"].tap()
        waitFor(app.staticTexts["Navigation app"])
        shot("17-settings")
        app.staticTexts["What ParcelPilot stores"].tap()
        waitFor(header("Never stored or uploaded"))
        shot("18-privacy")
    }

    func testLargeTextDeliverView() throws {
        launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        waitFor(app.segmentedControls["workspaceMode"]).buttons["Deliver"].tap()
        waitFor(app.buttons["delivered"])
        XCTAssertTrue(app.buttons["delivered"].isHittable, "Delivered stays reachable at large text sizes")
        shot("19-deliver-accessibility-large-text")
    }
    func expandPanel() {
        let handle = waitFor(app.buttons["panelHandle"])
        if !handle.label.contains("full height") { handle.tap() }
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'full height'"), object: handle)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 3), .completed)
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
        app.segmentedControls["workspaceMode"].buttons["Deliver"].tap()
        XCTAssertEqual(waitFor(app.staticTexts["nextStopAddress"]).label, "45 SAMPLE AVE")
        shot("21-selected-next-stop")
        let handle = app.buttons["panelHandle"]
        handle.press(forDuration: 0.1, thenDragTo: app.buttons["delivered"])
        XCTAssertTrue(app.staticTexts["nextStopAddress"].isHittable, "Collapsing delivery must leave the destination visible")
        XCTAssertTrue(app.buttons["delivered"].isHittable)
        shot("22-delivery-after-panel-drag")
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
        XCTAssertTrue(header("Packages (2)").exists)
        shot("24-package-search-details")
        let add = app.buttons["Add another package"]
        scrollTo(add, in: app.collectionViews.firstMatch)
        add.tap()
        waitFor(app.buttons["savePackage"])
        app.buttons["Cancel"].tap()
        XCTAssertTrue(header("Packages (2)").exists, "Cancel must not create a package")
        app.buttons["Add another package"].tap()
        waitFor(app.buttons["savePackage"]).tap()
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
        app.tabBars.buttons["History"].tap()
        waitFor(app.buttons["historyRow"]).tap()
        let reopen = app.buttons["Reopen route"]
        scrollTo(reopen, in: app.collectionViews.firstMatch)
        reopen.tap()
        waitFor(app.buttons["optimize"])
        XCTAssertTrue(app.tabBars.buttons["Route"].isSelected)
        shot("26-reopened-route")
    }

    func testPartialDeliveryFailureCancelAndExcludeUndo() throws {
        launch()
        app.segmentedControls["workspaceMode"].buttons["Deliver"].tap()
        let address = waitFor(app.staticTexts["nextStopAddress"]).label
        app.buttons["failed"].tap()
        XCTAssertFalse(waitFor(app.buttons["savePackageOutcome"]).isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.staticTexts["nextStopAddress"].label, address)
        app.buttons["delivered"].tap()
        waitFor(app.buttons["outcomePackage.1"]).tap()
        app.buttons["savePackageOutcome"].tap()
        XCTAssertEqual(app.staticTexts["nextStopAddress"].label, address, "The other package keeps this stop active")
        app.buttons["failed"].tap()
        XCTAssertFalse(waitFor(app.buttons["saveFailure"]).isEnabled)
        app.buttons["reason.noOneHome"].tap()
        app.buttons["saveFailure"].tap()
        let exclude = app.buttons["Exclude"].firstMatch
        scrollTo(exclude, in: app.scrollViews.firstMatch)
        exclude.tap()
        waitFor(app.buttons["Undo"]).tap()
        XCTAssertTrue(app.buttons["Retry later"].firstMatch.exists)
        shot("27-partial-delivery-decisions")
    }

    func testScanReviewTypingPhotoAndCSVFallbacks() throws {
        launch()
        app.tabBars.buttons["Scan"].tap()
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
        app.segmentedControls["workspaceMode"].buttons["Deliver"].tap()
        waitFor(app.buttons["skip"]).tap()
        let next = app.staticTexts["nextStopAddress"].label
        app.terminate()
        app.launchArguments = ["-PPDemoMode", "YES", "-PPSimulateOffline", "YES"]
        app.launch()
        waitFor(app.buttons["delivered"])
        XCTAssertEqual(app.staticTexts["nextStopAddress"].label, next)
        let retry = app.buttons["Retry later"].firstMatch
        scrollTo(retry, in: app.scrollViews.firstMatch)
        XCTAssertTrue(retry.exists)
        shot("30-offline-relaunch")
    }

    func testStopAddressPinAndDeliveryWindowEditing() throws {
        launch()
        waitFor(app.buttons["stopRow.1"]).tap()
        waitFor(app.buttons["editStopAddress"]).tap()
        waitFor(app.textFields["Number"]).tap()
        app.textFields["Number"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "321")
        waitFor(app.buttons["Check address"]).tap()
        let save = app.navigationBars["Edit address"].buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        waitFor(app.buttons["placeStopPin"]).tap()
        waitFor(app.buttons["Use this location"]).tap()
        XCTAssertTrue(waitFor(app.buttons["placeStopPin"]).label.contains("Move pin"), "The saved driver pin is shown as movable")
        app.buttons["Navigate"].tap()
        waitFor(app.buttons["Apple Maps"])
        XCTAssertTrue(app.buttons["Google Maps"].exists, "Ask each time works from stop details")
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.navigationBars["Stop 1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let window = app.buttons["deliveryTimePicker"]
        scrollTo(window, in: app.collectionViews.firstMatch)
        window.tap()
        waitFor(app.buttons["Prefer to arrive by"]).tap()
        let saveWindow = app.buttons["saveDeliveryTime"]
        scrollTo(saveWindow, in: app.collectionViews.firstMatch)
        saveWindow.tap()
        shot("31-stop-pin-and-time-window")
        app.buttons["Done"].tap()
        app.segmentedControls["workspaceMode"].buttons["Deliver"].tap()
        XCTAssertEqual(waitFor(app.staticTexts["nextStopAddress"]).label, "321 EXAMPLE ST")
    }

    func testNavigationReturnDoesNotDeliver() throws {
        launch()
        app.segmentedControls["workspaceMode"].buttons["Deliver"].tap()
        let address = waitFor(app.staticTexts["nextStopAddress"]).label
        app.buttons["navigate"].tap()
        waitFor(app.buttons["Apple Maps"]).tap()
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        XCTAssertTrue(maps.wait(for: .runningForeground, timeout: 15))
        app.activate()
        waitFor(app.descendants(matching: .any)["returnBanner"].firstMatch)
        XCTAssertEqual(app.staticTexts["nextStopAddress"].label, address)
        XCTAssertTrue(app.buttons["delivered"].isEnabled)
        shot("32-back-from-navigation")
    }

    func testOptimizeKeepCurrentOrderAndRouteSettings() throws {
        launch()
        let first = waitFor(app.buttons["stopRow.1"]).label
        app.buttons["optimize"].tap()
        waitFor(app.buttons["calculate"]).tap()
        let keep = waitFor(app.buttons["keepCurrentOrder"], timeout: 20)
        scrollTo(keep, in: app.collectionViews.firstMatch)
        keep.tap()
        XCTAssertEqual(app.buttons["stopRow.1"].label, first)
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
        let map = waitFor(app.maps.firstMatch)
        let marker = map.descendants(matching: .any).matching(NSPredicate(format: "label == 'Stop 7'")).firstMatch
        waitFor(marker).tap()
        let row = waitFor(app.buttons["stopRow.7"])
        XCTAssertTrue(row.isHittable, "Selecting a marker brings its stop into view")
        map.pinch(withScale: 1.5, velocity: 1)
        map.swipeLeft()
        shot("34-map-pan-and-zoom")
        row.tap()
        waitFor(app.navigationBars["Stop 7"])
        app.buttons["Done"].tap()
    }

    /// Seed the simulator photo library with fixtures/labels/e1_victoria_unit204.png using simctl
    /// addmedia, then run with TEST_RUNNER_PP_UI_PHOTO_FIXTURE=1. Ordinary runs skip this dependency.
    func testImportedLabelPhotoThroughRecognitionAndConfirmation() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PP_UI_PHOTO_FIXTURE"] == "1", "Requires the synthetic label fixture in the simulator photo library")
        launch()
        app.tabBars.buttons["Scan"].tap()
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

    /// Used by capture-screenshots.sh: wait for real controls instead of photographing a launch screen.
    func testPrimaryScreensForScreenshotAudit() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PP_UI_SCREEN_MATRIX"] == "1", "Screenshot audit only")
        launch()
        waitFor(app.buttons["optimize"])
        shot("matrix-plan")
        app.segmentedControls["workspaceMode"].buttons["Deliver"].tap()
        waitFor(app.buttons["delivered"])
        XCTAssertTrue(app.staticTexts["actionDestination"].isHittable)
        shot("matrix-deliver")
        app.tabBars.buttons["Scan"].tap()
        waitFor(app.buttons["typeAddress"])
        shot("matrix-scan")
        app.tabBars.buttons["History"].tap()
        waitFor(app.staticTexts["No finished routes"])
        shot("matrix-history")
        app.tabBars.buttons["Settings"].tap()
        waitFor(app.staticTexts["Navigation app"])
        shot("matrix-settings")
    }

}
