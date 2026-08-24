import Foundation
import MacNetXPC
import OSLog

/// Decides which connections the helper is willing to serve.
///
/// The real gate is `NSXPCListener.setConnectionCodeSigningRequirement(_:)`, applied when the
/// listener is created: the system evaluates the peer's audit token against our requirement
/// and never delivers a failing connection here at all. See `CallerRequirement` for why that
/// is the right mechanism rather than inspecting UID, PID, or paths.
///
/// This delegate therefore handles only what remains: configuring the accepted connection's
/// interfaces and exported object, and refusing everything if the helper could not establish
/// a requirement in the first place.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {

    private let logger = Logger(
        subsystem: HelperIdentity.bundleIdentifier,
        category: "listener"
    )

    /// True when the listener was successfully constrained by a code signing requirement.
    ///
    /// If it was not, every connection is refused. Serving anonymous callers from a root
    /// process would be strictly worse than being unavailable.
    private let isRequirementEnforced: Bool

    private let coordinator: SessionCoordinator

    init(isRequirementEnforced: Bool, coordinator: SessionCoordinator) {
        self.isRequirementEnforced = isRequirementEnforced
        self.coordinator = coordinator
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard isRequirementEnforced else {
            logger.fault("refusing connection: no code signing requirement is in force")
            return false
        }

        newConnection.exportedInterface = HelperInterface.makeServiceInterface()
        newConnection.exportedObject = HelperRequestHandler(coordinator: coordinator)

        // The app also exports an object, so the helper can push events without polling.
        newConnection.remoteObjectInterface = HelperInterface.makeClientInterface()

        newConnection.invalidationHandler = { [logger] in
            logger.log("client connection invalidated")
        }
        newConnection.interruptionHandler = { [logger] in
            logger.log("client connection interrupted")
        }

        newConnection.resume()
        logger.log("accepted verified client connection")
        return true
    }
}
