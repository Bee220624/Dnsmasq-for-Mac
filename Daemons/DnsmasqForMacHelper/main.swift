import Foundation
import OSLog

// Entry point for the privileged helper.
//
// launchd starts this process as root, on demand, when a client connects to the Mach service
// declared in the embedded LaunchDaemon plist. It is never started at boot and never runs on
// a schedule (ticket §10.1).
//
// Nothing privileged happens before the caller has been verified: HelperService constrains
// the listener with a code signing requirement, and the system refuses non-matching peers
// before any of our code sees them.

let bootLogger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "main")

bootLogger.log(
    """
    helper starting: version=\(HelperIdentity.version, privacy: .public) \
    protocol=\(HelperIdentity.protocolVersion, privacy: .public) \
    euid=\(geteuid(), privacy: .public)
    """
)

// A helper that is not root cannot do its job, and continuing would turn a clear
// configuration problem into confusing downstream permission failures.
guard geteuid() == 0 else {
    bootLogger.fault("helper must run as root, effective uid is \(geteuid(), privacy: .public)")
    exit(EXIT_FAILURE)
}

HelperService.shared.run()
