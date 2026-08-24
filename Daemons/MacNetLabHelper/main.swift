import Foundation
import OSLog

// Entry point for the privileged helper.
//
// This process is started on demand by launchd as root when the app connects to the Mach
// service declared in the embedded LaunchDaemon plist. It must never do anything before the
// caller has been validated; the listener delegate in HelperListenerDelegate is what decides
// whether a connection is allowed to exist at all.
//
// Phase 1 establishes the target, its Info.plist section, and the launchd handshake shape.
// Phase 2 replaces the body below with the real NSXPCListener and caller validation.

let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "main")

logger.log(
    """
    helper starting: version=\(HelperIdentity.version, privacy: .public) \
    protocol=\(HelperIdentity.protocolVersion, privacy: .public) \
    euid=\(geteuid(), privacy: .public)
    """
)

// A helper that is not root cannot do its job, and silently continuing would produce
// confusing downstream failures. Refusing loudly is the correct response.
guard geteuid() == 0 else {
    logger.fault("helper must run as root, effective uid is \(geteuid(), privacy: .public)")
    exit(EXIT_FAILURE)
}

HelperService.shared.run()
