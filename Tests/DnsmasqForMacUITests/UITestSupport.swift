import XCTest

/// Shared launch and interaction helpers for the UI tests.
///
/// Three things here exist because the first real run of these tests failed on all three, and
/// every one of them was the test's fault rather than the app's.
extension XCUIApplication {

    /// Launches the app in a state that does not depend on the machine running the tests.
    ///
    /// * **Language is forced to English.** The app is localized into Simplified Chinese, so on
    ///   a Chinese system every assertion about visible text compared `"已停止"` against
    ///   `"Stopped"` and failed. A UI test that only passes in one system language is testing
    ///   the tester's Mac, not the product.
    ///
    /// * **State restoration is disabled.** macOS had persisted a split-view geometry 2174 pt
    ///   tall — far beyond the 944 pt screen — which put the sidebar items at a negative Y and
    ///   made every one of them report "not hittable". Restored geometry from a previous run
    ///   must not decide whether this run passes.
    static func launchForUITesting() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    /// Finds an element by accessibility identifier, whatever kind it is.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier]
    }
}

extension XCTestCase {

    /// Waits for an element to become hittable, not merely to exist.
    ///
    /// `waitForExistence` returns as soon as the element is in the tree, which on macOS happens
    /// well before the window has been laid out and brought forward. Clicking then fails with
    /// "not hittable" and reads like a missing control.
    @MainActor
    @discardableResult
    func waitUntilHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("\(element) never appeared", file: file, line: line)
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail("\(element) exists but never became hittable", file: file, line: line)
        return false
    }

    /// Selects a sidebar destination and waits for its page.
    @MainActor
    func selectSidebar(
        _ section: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let item = app.element("sidebar.\(section)")
        guard waitUntilHittable(item, file: file, line: line) else { return }
        item.click()

        let page = app.element("\(section).page")
        XCTAssertTrue(
            page.waitForExistence(timeout: 10),
            "the \(section) page should appear after selecting it",
            file: file, line: line
        )
    }

    /// Waits for an element to appear, allowing for work that has to finish first.
    ///
    /// Several screens settle asynchronously — the helper status starts as "checking" and only
    /// then resolves to "not installed" — so asserting immediately after launch tests the
    /// loading state rather than the one that matters.
    @MainActor
    @discardableResult
    func waitForElement(
        _ element: XCUIElement,
        timeout: TimeInterval = 15,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let appeared = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(appeared, message, file: file, line: line)
        return appeared
    }
}
