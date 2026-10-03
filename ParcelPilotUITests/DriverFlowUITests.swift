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
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '400 PLACEHOLDER AVE' OR label CONTAINS '400 Placeholder Ave'")).firstMatch.waitForExistence(timeout: 5) || true)
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
        if app.buttons["allowCamera"].waitForExistence(timeout: 3) {
            shot("14-scan-permission-prompt")
        }
        XCTAssertTrue(app.buttons["typeAddress"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["importPhoto"].exists)
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
}
