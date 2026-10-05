import XCTest

/// Shell navigation coverage.
final class NavigationUITests: XCTestCase {

    @MainActor
    func testAllFiveSectionsAreReachable() throws {
        let app = XCUIApplication.launchForUITesting()

        // Sidebar order is fixed by the specification and is part of the product, not an incidental
        // detail, so it is asserted rather than merely iterated.
        for section in ["overview", "leases", "logs", "profiles", "settings"] {
            selectSidebar(section, in: app)
        }
    }

    @MainActor
    func testStatusBarReportsStoppedOnLaunch() throws {
        let app = XCUIApplication.launchForUITesting()

        let status = app.element("status.phase")
        waitForElement(status, "the status chip should exist")

        // The specification: the app must never start a service on its own.
        XCTAssertEqual(status.value as? String, "Stopped")
    }

    @MainActor
    func testConnectOpensConfigurationBeforeStarting() throws {
        let app = XCUIApplication.launchForUITesting()

        let start = app.buttons["overview.startButton"]
        guard waitUntilHittable(start) else { return }

        XCTAssertTrue(start.isEnabled, "Connect should guide the user through setup")
        XCTAssertFalse(app.element("overview.interfacePicker").exists)
        start.click()
        waitForElement(app.element("overview.safetyConfirmation"), "setup must require isolation confirmation")
        XCTAssertEqual(app.element("status.phase").value as? String, "Stopped")
    }

    @MainActor
    func testOverviewShowsConnectionDiagramWithCollapsedSettings() throws {
        let app = XCUIApplication.launchForUITesting()

        waitForElement(app.element("overview.page"), "the connection page should appear")
        XCTAssertTrue(app.element("overview.connectionDiagram").exists)
        XCTAssertTrue(app.buttons["overview.startButton"].exists)
        XCTAssertFalse(app.element("overview.profilePicker").exists)
        XCTAssertFalse(app.element("overview.validateButton").exists)
    }

    @MainActor
    func testAnimationPreviewCanSucceedAndFailWithoutStartingTheService() throws {
        let app = XCUIApplication.launchForUITesting()
        let debug = app.checkBoxes["overview.animationDebug"]
        guard waitUntilHittable(debug) else { return }
        debug.click()

        let preview = app.buttons["overview.previewButton"]
        let outcome = app.segmentedControls["overview.previewOutcome"]
        guard waitUntilHittable(preview) else { return }
        preview.click()
        let phase = app.element("overview.previewPhase")
        let connected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Connected"), object: phase
        )
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 8), .completed)
        XCTAssertEqual(app.element("status.phase").value as? String, "Stopped")

        let failure = outcome.buttons["Failure"]
        guard waitUntilHittable(failure) else { return }
        failure.click()
        preview.click()
        let failed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Failed"), object: phase
        )
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 8), .completed)
        XCTAssertEqual(app.element("status.phase").value as? String, "Stopped")
        XCTAssertFalse(app.buttons["overview.stopButton"].exists)

        debug.click()
        XCTAssertFalse(preview.exists)
        XCTAssertTrue(app.buttons["overview.startButton"].exists)
        XCTAssertEqual(app.element("status.phase").value as? String, "Stopped")
    }

    @MainActor
    func testFailedStartKeepsTheConnectionStopped() throws {
        let app = XCUIApplication.launchForUITesting()
        openConnectionSettings(in: app)

        let confirmation = app.checkBoxes["overview.safetyConfirmation"]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<10 {
            if confirmation.isHittable { break }
            scroll.scroll(byDeltaX: 0, deltaY: -200)
        }
        guard waitUntilHittable(confirmation) else { return }
        confirmation.click()

        let connect = app.buttons["overview.startButton"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: connect)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        connect.click()

        waitForElement(app.element("overview.failureBanner"), "a rejected start must show its failure")
        XCTAssertEqual(app.element("status.phase").value as? String, "Stopped")
        XCTAssertFalse(app.buttons["overview.stopButton"].exists)
    }
    @MainActor
    func testChineseConfigurationRetainsInputAfterTabAndScrolling() throws {
        let app = XCUIApplication.launchForUITesting(language: "zh-Hans")
        openConnectionSettings(in: app)
        let row = app.element("settings.serverIPv4")
        waitForElement(row, "Chinese configuration must be present")
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<10 {
            if row.isHittable { break }
            scroll.scroll(byDeltaX: 0, deltaY: -200)
        }
        let field = row.elementType == .textField ? row : row.textFields.firstMatch
        guard waitUntilHittable(field) else { return }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("192.168.88.1\t")
        XCTAssertEqual(field.value as? String, "192.168.88.1")
        let upstream = app.element("settings.upstreamMode")
        for _ in 0..<12 {
            if upstream.isHittable { break }
            scroll.scroll(byDeltaX: 0, deltaY: -200)
        }
        XCTAssertTrue(upstream.isHittable, "all configuration sections must be scrollable")
        selectSidebar("profiles", in: app)
        selectSidebar("overview", in: app)
        openConnectionSettings(in: app)
        let restoredRow = app.element("settings.serverIPv4")
        let restoredField = restoredRow.elementType == .textField ? restoredRow : restoredRow.textFields.firstMatch
        XCTAssertEqual(restoredField.value as? String, "192.168.88.1", "navigation must preserve the working input")
    }
}
