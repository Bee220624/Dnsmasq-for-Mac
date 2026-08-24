import XCTest

/// Profile management UI coverage (ticket §Phase 6, §24.3).
///
/// Not runnable in a non-interactive session — see `Docs/RISKS.md` R-11. Run with
/// `make test-ui`.
final class ProfileUITests: XCTestCase {

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        return app
    }

    @MainActor
    func testProfileCardIsPresentOnOverview() throws {
        let app = launchApp()
        let picker = app.descendants(matching: .any)["overview.profilePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
    }

    @MainActor
    func testSaveAndRevertAreDisabledWithoutChanges() throws {
        let app = launchApp()

        let save = app.buttons["overview.saveProfile"]
        let revert = app.buttons["overview.revertProfile"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))

        // Nothing has been edited, so there is nothing to save or undo. Enabled buttons here
        // would suggest the profile is dirty when it is not.
        XCTAssertFalse(save.isEnabled)
        XCTAssertFalse(revert.isEnabled)
    }

    @MainActor
    func testUnsavedIndicatorIsAbsentInitially() throws {
        let app = launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["overview.profilePicker"]
            .waitForExistence(timeout: 10))

        // A freshly loaded profile must not claim to have unsaved changes; otherwise the
        // indicator stops meaning anything.
        XCTAssertFalse(app.descendants(matching: .any)["overview.unsavedChanges"].exists)
    }

    @MainActor
    func testProfilesPageListsAtLeastOneProfile() throws {
        let app = launchApp()

        app.descendants(matching: .any)["sidebar.profiles"].click()

        let list = app.descendants(matching: .any)["profiles.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        // Ticket §5.6: one profile must always exist.
        XCTAssertGreaterThan(list.descendants(matching: .staticText).count, 0)
    }

    @MainActor
    func testDeleteIsRefusedForTheOnlyProfile() throws {
        let app = launchApp()

        app.descendants(matching: .any)["sidebar.profiles"].click()
        XCTAssertTrue(app.descendants(matching: .any)["profiles.list"]
            .waitForExistence(timeout: 10))

        // On a fresh install there is exactly one profile, and it is the default — both
        // reasons deletion must be unavailable.
        let delete = app.buttons["profiles.delete"]
        XCTAssertTrue(delete.exists)
        XCTAssertFalse(delete.isEnabled)
    }
}
