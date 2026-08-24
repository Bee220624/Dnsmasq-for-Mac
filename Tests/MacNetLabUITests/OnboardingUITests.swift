import XCTest

/// Onboarding, Settings, and accessibility coverage (ticket §Phase 11, §24.3).
///
/// Not runnable in a non-interactive session — XCUITest needs a macOS automation
/// authorization only a human can grant. See `Docs/RISKS.md` R-11; run with `make test-ui`.
final class OnboardingUITests: XCTestCase {

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        return app
    }

    @MainActor
    func testOnboardingIsShownWhenTheHelperIsNotInstalled() throws {
        let app = launchApp()

        // With no helper, Overview must explain the one thing the user has to do rather than
        // present a page of disabled controls with no reason given.
        let onboarding = app.descendants(matching: .any)["onboarding.page"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10))

        let install = app.descendants(matching: .any)["onboarding.installHelper"]
        XCTAssertTrue(install.exists, "the install action should be offered")
    }

    @MainActor
    func testSettingsShowsHelperAndEngineStatus() throws {
        let app = launchApp()
        app.descendants(matching: .any)["sidebar.settings"].click()

        XCTAssertTrue(app.descendants(matching: .any)["settings.page"]
            .waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["settings.helperStatus"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings.verifyEngine"].exists)
    }

    @MainActor
    func testThirdPartyNoticesAreReachable() throws {
        // Ticket §23 requires the licences to be visible in the app, not merely shipped in the
        // bundle where nobody would find them.
        let app = launchApp()
        app.descendants(matching: .any)["sidebar.settings"].click()

        let notices = app.descendants(matching: .any)["settings.thirdPartyNotices"]
        XCTAssertTrue(notices.waitForExistence(timeout: 10))
    }

    @MainActor
    func testEverySidebarItemHasAnAccessibilityLabel() throws {
        // VoiceOver must be able to name every destination (ticket §26.2).
        let app = launchApp()

        for section in ["overview", "leases", "logs", "profiles", "settings"] {
            let item = app.descendants(matching: .any)["sidebar.\(section)"]
            XCTAssertTrue(item.waitForExistence(timeout: 10))
            XCTAssertFalse(
                (item.label).isEmpty,
                "sidebar.\(section) should have a label for VoiceOver"
            )
        }
    }

    @MainActor
    func testServiceStatusExposesAValueNotJustAColour() throws {
        let app = launchApp()

        // Ticket §5.2 and §26.2: state is never conveyed by colour alone, so the status
        // element must carry a readable value.
        let status = app.descendants(matching: .any)["status.phase"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.value as? String, "Stopped")
    }

    @MainActor
    func testLogsControlsArePresent() throws {
        let app = launchApp()
        app.descendants(matching: .any)["sidebar.logs"].click()

        XCTAssertTrue(app.descendants(matching: .any)["logs.page"]
            .waitForExistence(timeout: 10))
        for identifier in ["logs.searchField", "logs.categoryPicker",
                           "logs.pauseButton", "logs.clearButton", "logs.exportButton"] {
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].exists,
                "\(identifier) should be present"
            )
        }
    }

    @MainActor
    func testLeasesShowsTheNotRunningEmptyState() throws {
        let app = launchApp()
        app.descendants(matching: .any)["sidebar.leases"].click()

        // The three "no leases" situations must look different from each other; with nothing
        // running it must be this one.
        let empty = app.descendants(matching: .any)["leases.emptyNotRunning"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
    }
}
