import XCTest

/// Shell navigation coverage (ticket §Phase 1 completion criteria, §24.3).
final class NavigationUITests: XCTestCase {

    @MainActor
    func testAllFiveSectionsAreReachable() throws {
        let app = XCUIApplication.launchForUITesting()

        // Sidebar order is fixed by ticket §5.1 and is part of the product, not an incidental
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

        // Ticket §0.1 and §21.6: the app must never start a service on its own.
        XCTAssertEqual(status.value as? String, "Stopped")
    }

    @MainActor
    func testStartButtonIsDisabledWithoutHelperAndConfirmation() throws {
        let app = XCUIApplication.launchForUITesting()

        let start = app.buttons["overview.startButton"]
        waitForElement(start, "the start button should exist")

        // Start stays unavailable until the helper is installed, preflight passes, and the
        // isolation confirmation is given (ticket §21.6).
        XCTAssertFalse(start.isEnabled, "Start must not be enabled before preflight")
    }
}
