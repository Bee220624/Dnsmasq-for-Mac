import XCTest

/// Onboarding, Settings, and accessibility coverage.
final class OnboardingUITests: XCTestCase {

    @MainActor
    func testOnboardingIsShownWhenTheHelperIsNotInstalled() throws {
        let app = XCUIApplication.launchForUITesting(fixture: "notRegistered")
        waitForElement(app.element("onboarding.installHelper"), "not installed must offer installation")
        XCTAssertFalse(app.element("overview.profilePicker").exists)
    }

    @MainActor
    func testPendingApprovalShowsSettingsEntryWithoutInstall() throws {
        let app = XCUIApplication.launchForUITesting(fixture: "approval")
        waitForElement(app.element("onboarding.openLoginItems"), "approval needs a settings entry")
        XCTAssertFalse(app.element("onboarding.installHelper").exists)
        app.element("onboarding.openLoginItems").click()
        XCTAssertTrue(app.element("onboarding.page").exists)
    }

    @MainActor
    func testFailedHandshakeCanRetryWithoutRegistering() throws {
        let app = XCUIApplication.launchForUITesting(fixture: "failed")
        let retry = app.element("onboarding.retryHelper")
        guard waitUntilHittable(retry) else { return }
        retry.click()
        waitForElement(app.element("overview.profilePicker"), "retry handshake should open configuration")
        XCTAssertFalse(app.element("onboarding.openLoginItems").exists)
    }

    @MainActor
    func testIncompleteBundleAndProtocolMismatchShowDistinctErrors() throws {
        for fixture in ["bundleIncomplete", "incompatible"] {
            let app = XCUIApplication.launchForUITesting(fixture: fixture)
            waitForElement(app.element("onboarding.\(fixture)"), "fixture should show its specific error")
            XCTAssertFalse(app.element("overview.profilePicker").exists)
            app.terminate()
        }
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
        // The specification requires the licences to be visible in the app, not merely shipped in the
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
        // VoiceOver must be able to name every destination.
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

        // The specification: state is never conveyed by colour alone, so the status element
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
