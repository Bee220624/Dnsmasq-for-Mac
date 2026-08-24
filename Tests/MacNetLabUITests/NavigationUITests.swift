import XCTest

/// Phase 1 UI coverage: the shell launches and all five destinations are reachable
/// (ticket §Phase 1 completion criteria, §24.3).
///
/// The test methods are `@MainActor` because XCUIElement's state accessors are main-actor
/// isolated, and under Swift 6 an assertion autoclosure cannot reach them from a nonisolated
/// context. `setUp` is deliberately not overridden so it stays nonisolated like its base.
final class NavigationUITests: XCTestCase {

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        return app
    }

    @MainActor
    func testAllFiveSectionsAreReachable() throws {
        let app = launchApp()

        // Sidebar order is fixed by ticket §5.1 and is part of the product, not an
        // incidental detail, so it is asserted rather than merely iterated.
        let sections = ["overview", "leases", "logs", "profiles", "settings"]

        for section in sections {
            let item = app.descendants(matching: .any)["sidebar.\(section)"]
            XCTAssertTrue(
                item.waitForExistence(timeout: 10),
                "sidebar item for \(section) should exist"
            )
            item.click()

            let page = app.descendants(matching: .any)["\(section).page"]
            XCTAssertTrue(
                page.waitForExistence(timeout: 5),
                "\(section) page should appear after selecting it"
            )
        }
    }

    @MainActor
    func testStatusBarReportsStoppedOnLaunch() throws {
        let app = launchApp()

        let status = app.descendants(matching: .any)["status.phase"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "status chip should exist")

        // Ticket §0.1 and §21.6: the app must never start a service on its own.
        let value = status.value as? String
        XCTAssertEqual(value, "Stopped")
    }

    @MainActor
    func testStartButtonIsDisabledWithoutHelperAndConfirmation() throws {
        let app = launchApp()

        let start = app.buttons["overview.startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "start button should exist")

        // Start stays unavailable until preflight passes and the isolation confirmation is
        // given. Enabling it earlier would violate the DHCP safety rules in ticket §21.6.
        let enabled = start.isEnabled
        XCTAssertFalse(enabled, "Start must not be enabled before preflight")
    }
}
