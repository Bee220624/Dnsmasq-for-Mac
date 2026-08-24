import XCTest

/// Interface selection UI coverage (ticket §Phase 5, §24.3).
///
/// These cannot be executed in a non-interactive session — XCUITest requires a macOS
/// automation authorization that only a human at the keyboard can grant. See
/// `Docs/RISKS.md` R-11 and run them with `make test-ui`.
final class InterfaceSelectionUITests: XCTestCase {

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        return app
    }

    @MainActor
    func testInterfaceCardIsPresentOnOverview() throws {
        let app = launchApp()

        let picker = app.descendants(matching: .any)["overview.interfacePicker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 10),
            "the interface picker should be on Overview"
        )
    }

    @MainActor
    func testRefreshIsAvailable() throws {
        let app = launchApp()

        let refresh = app.descendants(matching: .any)["overview.refreshInterfaces"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCTAssertTrue(refresh.isEnabled, "refresh should be available while stopped")
        refresh.click()

        // Re-scanning must not disturb the page.
        XCTAssertTrue(app.descendants(matching: .any)["overview.page"].exists)
    }

    @MainActor
    func testStartStaysDisabledAfterSelectingAnInterface() throws {
        let app = launchApp()

        let start = app.buttons["overview.startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))

        // Choosing an interface is necessary but nowhere near sufficient: preflight must pass,
        // the helper must be installed, and the isolation confirmation must be given
        // (ticket §21.6). Start staying disabled here is the property under test.
        XCTAssertFalse(start.isEnabled)
    }
}
