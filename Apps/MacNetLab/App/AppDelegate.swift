import AppKit

/// Application delegate.
///
/// Its real job arrives with the session lifecycle: ticket §17.2 requires that quitting
/// while services are running prompts the user and stops them asynchronously via
/// `applicationShouldTerminate`. Until the session coordinator exists there is nothing
/// running to stop, so termination proceeds immediately.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
