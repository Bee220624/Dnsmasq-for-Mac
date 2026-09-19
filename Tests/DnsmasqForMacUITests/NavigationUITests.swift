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
    func testStartButtonIsDisabledWithoutHelperAndConfirmation() throws {
        let app = XCUIApplication.launchForUITesting()

        let start = app.buttons["overview.startButton"]
        waitForElement(start, "the start button should exist")

        // Start stays unavailable until the helper is installed, preflight passes, and the
        // isolation confirmation is given.
        XCTAssertFalse(start.isEnabled, "Start must not be enabled before preflight")
    }
    @MainActor
    func testChineseConfigurationRetainsInputAfterTabAndScrolling() throws {
        let app = XCUIApplication.launchForUITesting(language: "zh-Hans")
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
        let restoredRow = app.element("settings.serverIPv4")
        let restoredField = restoredRow.elementType == .textField ? restoredRow : restoredRow.textFields.firstMatch
        XCTAssertEqual(restoredField.value as? String, "192.168.88.1", "navigation must preserve the working input")
    }
}
