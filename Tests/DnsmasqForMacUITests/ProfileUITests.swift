import XCTest

/// Profile management coverage.
final class ProfileUITests: XCTestCase {

    @MainActor
    private func isConfigurationShown(_ app: XCUIApplication) -> Bool {
        app.element("overview.profilePicker").waitForExistence(timeout: 5)
    }

    @MainActor
    func testProfileCardIsPresentWhenTheHelperIsReady() throws {
        let app = XCUIApplication.launchForUITesting()

        XCTAssertTrue(isConfigurationShown(app), "ready fixture must show configuration")
        XCTAssertTrue(app.element("overview.profilePicker").exists)
    }

    @MainActor
    func testSaveAndRevertAreDisabledWithoutChanges() throws {
        let app = XCUIApplication.launchForUITesting()

        XCTAssertTrue(isConfigurationShown(app), "ready fixture must show configuration")

        // Nothing has been edited, so there is nothing to save or undo. Enabled buttons would
        // suggest the profile is dirty when it is not.
        XCTAssertFalse(app.buttons["overview.saveProfile"].isEnabled)
        XCTAssertFalse(app.buttons["overview.revertProfile"].isEnabled)
        XCTAssertFalse(app.element("overview.unsavedChanges").exists)
    }

    @MainActor
    func testProfilesPageListsAtLeastOneProfile() throws {
        let app = XCUIApplication.launchForUITesting()
        selectSidebar("profiles", in: app)

        let list = app.element("profiles.list")
        waitForElement(list, "the profile list should exist")
        // The specification: one profile must always exist.
        XCTAssertGreaterThan(list.descendants(matching: .staticText).count, 0)
    }

    @MainActor
    func testDeleteIsRefusedForTheOnlyProfile() throws {
        let app = XCUIApplication.launchForUITesting()
        selectSidebar("profiles", in: app)

        // On a fresh install there is exactly one profile and it is the default — both reasons
        // deletion must be unavailable.
        let delete = app.buttons["profiles.delete"]
        waitForElement(delete, "the delete button should exist")
        XCTAssertFalse(delete.isEnabled)
    }
}
