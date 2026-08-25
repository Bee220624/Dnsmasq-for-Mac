import XCTest

/// Interface selection coverage (ticket §Phase 5, §24.3).
///
/// These controls live on Overview's configuration view, which is only shown once the helper is
/// usable. With no helper installed the page shows onboarding instead — so each test states
/// which of the two it expects rather than assuming.
final class InterfaceSelectionUITests: XCTestCase {

    /// True when Overview is showing configuration rather than onboarding.
    @MainActor
    private func isConfigurationShown(_ app: XCUIApplication) -> Bool {
        app.element("overview.interfacePicker").waitForExistence(timeout: 5)
    }

    @MainActor
    func testOverviewShowsEitherOnboardingOrConfiguration() throws {
        let app = XCUIApplication.launchForUITesting()

        // Exactly one of the two, never neither. A blank Overview would be indistinguishable
        // from a page that failed to load.
        let onboarding = app.element("onboarding.page")
        let picker = app.element("overview.interfacePicker")

        let settled = onboarding.waitForExistence(timeout: 15)
            || picker.waitForExistence(timeout: 5)
        XCTAssertTrue(settled, "Overview must show onboarding or the configuration cards")
    }

    @MainActor
    func testInterfaceCardIsPresentWhenTheHelperIsReady() throws {
        let app = XCUIApplication.launchForUITesting()

        try XCTSkipUnless(
            isConfigurationShown(app),
            "the privileged helper is not installed, so Overview shows onboarding"
        )
        XCTAssertTrue(app.element("overview.interfacePicker").exists)
    }

    @MainActor
    func testRefreshIsAvailableWhenTheHelperIsReady() throws {
        let app = XCUIApplication.launchForUITesting()

        try XCTSkipUnless(
            isConfigurationShown(app),
            "the privileged helper is not installed, so Overview shows onboarding"
        )

        let refresh = app.element("overview.refreshInterfaces")
        guard waitUntilHittable(refresh) else { return }
        XCTAssertTrue(refresh.isEnabled, "refresh should be available while stopped")
        refresh.click()

        // Re-scanning must not disturb the page.
        XCTAssertTrue(app.element("overview.page").exists)
    }

    @MainActor
    func testStartStaysDisabledWhateverOverviewShows() throws {
        let app = XCUIApplication.launchForUITesting()

        let start = app.buttons["overview.startButton"]
        waitForElement(start, "the start button should exist")

        // Choosing an interface is necessary but nowhere near sufficient: the helper must be
        // installed, preflight must pass, and the isolation confirmation must be given.
        XCTAssertFalse(start.isEnabled)
    }
}
