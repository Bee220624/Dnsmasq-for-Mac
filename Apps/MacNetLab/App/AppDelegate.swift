import AppKit
import OSLog

/// Application delegate.
///
/// Its one real job is termination: ticket §17.2 requires that quitting while services are
/// running asks the user rather than silently leaving dnsmasq and a temporary IP alias behind.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by the App scene once the controller exists.
    ///
    /// A delegate is created by AppKit before any SwiftUI state, so it cannot own the
    /// controller — this is how the two are joined without either constructing the other.
    @MainActor static weak var sessionController: SessionController?

    private let logger = Logger(subsystem: "com.bee.macnetlab", category: "app-delegate")

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Asks before quitting with a session running (ticket §17.2).
    ///
    /// Returns `.terminateLater` and finishes asynchronously, because stopping involves XPC to
    /// the helper, terminating dnsmasq, and removing the alias — none of which can be done from
    /// a synchronous decision.
    @MainActor
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let controller = Self.sessionController, controller.isRunning else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "MacNetLab services are still running.")
        // A single literal: String(localized:) extracts the key at compile time, so a
        // concatenation would neither compile nor be extractable for translation.
        alert.informativeText = String(localized: "If you quit without stopping, DHCP and DNS keep running and the temporary IP address stays on the interface until you start MacNetLab again.")
        alert.alertStyle = .warning

        // Default first. Ticket §17.2 names this as the default because it is the option that
        // leaves the machine as the user found it.
        alert.addButton(withTitle: String(localized: "Stop Services and Quit"))
        alert.addButton(withTitle: String(localized: "Quit Without Stopping"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            logger.log("stopping services before quitting")
            Task { @MainActor in
                await controller.stop()

                // If the stop failed, the machine is not back to how it was — most likely an
                // alias that could not be removed. Quitting anyway would hide it, so the app
                // stays open with the error on screen.
                if controller.lastFailure != nil {
                    self.logger.error("stop failed; cancelling termination so the user sees it")
                    sender.reply(toApplicationShouldTerminate: false)
                } else {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater

        case .alertSecondButtonReturn:
            // A deliberate choice, and a legitimate one: the engineer may want the network to
            // stay up while they reboot a device. The helper keeps running, and the next launch
            // re-adopts the session (ticket §17.1).
            logger.log("quitting without stopping; the helper keeps the session running")
            return .terminateNow

        default:
            return .terminateCancel
        }
    }
}
