import XCTest

/// Onboarding, Settings, and accessibility coverage (ticket §Phase 11, §24.3).
final class OnboardingUITests: XCTestCase {

    @MainActor
    func testOnboardingIsShownWhenTheHelperIsNotInstalled() throws {
        let app = XCUIApplication.launchForUITesting()

        let onboarding = app.element("onboarding.page")
        try XCTSkipUnless(
            onboarding.waitForExistence(timeout: 15),
            "the privileged helper is installed, so onboarding is not shown"
        )

        // Helper status settles asynchronously: it begins as "checking" and shows a spinner,
        // then resolves. Asserting immediately would test the loading state.
        let install = app.element("onboarding.installHelper")
        let approval = app.element("onboarding.openLoginItems")

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !install.exists, !approval.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        // One of the two, depending on how far a previous install got.
        XCTAssertTrue(
            install.exists || approval.exists,
            "onboarding must offer an action, not just an explanation"
        )
    }

    @MainActor
    func testSettingsShowsHelperAndEngineStatus() throws {
        let app = XCUIApplication.launchForUITesting()
        selectSidebar("settings", in: app)

        XCTAssertTrue(app.element("settings.helperStatus").exists)
        XCTAssertTrue(app.element("settings.verifyEngine").exists)
    }

    @MainActor
    func testThirdPartyNoticesAreReachable() throws {
        // Ticket §23 requires the licences to be visible in the app, not merely shipped in the
        // bundle where nobody would find them.
        let app = XCUIApplication.launchForUITesting()
        selectSidebar("settings", in: app)

        waitForElement(
            app.element("settings.thirdPartyNotices"),
            "the third-party notices should be reachable from Settings"
        )
    }

    @MainActor
    func testEverySidebarItemHasAnAccessibilityLabel() throws {
        // VoiceOver must be able to name every destination (ticket §26.2).
        let app = XCUIApplication.launchForUITesting()

        for section in ["overview", "leases", "logs", "profiles", "settings"] {
            let item = app.element("sidebar.\(section)")
            waitForElement(item, "sidebar.\(section) should exist")
            XCTAssertFalse(
                item.label.isEmpty,
                "sidebar.\(section) should have a label for VoiceOver"
            )
        }
    }

    @MainActor
    func testServiceStatusExposesAValueNotJustAColour() throws {
        let app = XCUIApplication.launchForUITesting()

        // Ticket §5.2 and §26.2: state is never conveyed by colour alone, so the status element
        // must carry a readable value.
        let status = app.element("status.phase")
        waitForElement(status, "the status chip should exist")
        XCTAssertEqual(status.value as? String, "Stopped")
    }

    @MainActor
    func testLogsControlsArePresent() throws {
        let app = XCUIApplication.launchForUITesting()
        selectSidebar("logs", in: app)

        for identifier in ["logs.searchField", "logs.categoryPicker",
                           "logs.pauseButton", "logs.clearButton", "logs.exportButton"] {
            XCTAssertTrue(
                app.element(identifier).exists,
                "\(identifier) should be present"
            )
        }
    }

    @MainActor
    func testLeasesShowsTheNotRunningEmptyState() throws {
        let app = XCUIApplication.launchForUITesting()
        selectSidebar("leases", in: app)

        // The three "no leases" situations must look different from each other; with nothing
        // running it must be this one.
        waitForElement(
            app.element("leases.emptyNotRunning"),
            "Leases should say there is no active session"
        )
    }
}
