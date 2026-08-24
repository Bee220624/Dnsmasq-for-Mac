import Foundation
import MacNetInterfaces
import MacNetModels
import MacNetXPC
import OSLog

/// The object exported to a verified client — the helper's entire externally reachable
/// surface (ticket §10.5).
///
/// Every method here is a fixed, named operation. There is deliberately no way for a caller to
/// name a command, an executable, or a path: the operations that need them derive them from the
/// helper's own location and from identifiers the helper generated itself.
///
/// This type does no work of its own. It decodes, delegates to the `SessionCoordinator`, and
/// encodes — so the transport layer stays free of policy, and the policy stays testable without
/// a transport.
///
/// `@unchecked Sendable` is sound here rather than a papering-over: both stored properties are
/// `let` and Sendable (an actor reference and a logger), and the class is final. The unchecked
/// part is only needed because `NSObject`, which the XPC interface requires, is not Sendable.
final class HelperRequestHandler: NSObject, MacNetLabHelperProtocol, @unchecked Sendable {

    private let logger = Logger(
        subsystem: HelperIdentity.bundleIdentifier,
        category: "requests"
    )

    private let coordinator: SessionCoordinator

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    // MARK: - Identity

    func getServiceInfo(withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        let info = HelperServiceInfo(
            helperVersion: HelperIdentity.version,
            protocolVersion: HelperIdentity.protocolVersion,
            effectiveUID: geteuid(),
            buildType: HelperIdentity.buildType,
            bundleIdentifier: HelperIdentity.bundleIdentifier
        )

        logger.log(
            """
            getServiceInfo: version=\(info.helperVersion, privacy: .public) \
            protocol=\(info.protocolVersion, privacy: .public) \
            euid=\(info.effectiveUID, privacy: .public) \
            build=\(info.buildType.rawValue, privacy: .public)
            """
        )
        Self.respond(with: info, to: reply)
    }

    // MARK: - Status

    func getRuntimeStatus(withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        Task {
            let state = await coordinator.runtimeStatus()
            Self.respond(with: state, to: reply)
        }
    }

    // MARK: - Lifecycle

    func runPreflight(
        requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        Task {
            do {
                let request = try XPCPayload.decodeRequest(
                    SessionStartRequest.self, from: requestData
                )
                let report = await coordinator.preflight(request: request)
                Self.respond(with: report, to: reply)
            } catch {
                Self.respond(failure: error, to: reply)
            }
        }
    }

    func startSession(
        requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        Task {
            do {
                let request = try XPCPayload.decodeRequest(
                    SessionStartRequest.self, from: requestData
                )
                let session = try await coordinator.start(request: request)
                Self.respond(with: session, to: reply)
            } catch {
                Self.respond(failure: error, to: reply)
            }
        }
    }

    func stopSession(
        sessionID: String,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        Task {
            // A `String` on the wire because the interface is Objective-C. Parsing it into a
            // UUID here means a malformed identifier is refused before it reaches any logic,
            // and a session id can never be used to build a path.
            guard let identifier = UUID(uuidString: sessionID) else {
                Self.respond(
                    failure: ServiceFailure.invalidRequest("not a session identifier"),
                    to: reply
                )
                return
            }
            do {
                try await coordinator.stop(sessionID: identifier)
                Self.respond(with: EmptyReply(), to: reply)
            } catch {
                Self.respond(failure: error, to: reply)
            }
        }
    }

    func recoverStaleState(withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        Task {
            let report = await coordinator.recoverStaleState()
            Self.respond(with: report, to: reply)
        }
    }

    // MARK: - Awaiting their phase

    func getLeaseSnapshot(
        sessionID: String,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        Task {
            guard let identifier = UUID(uuidString: sessionID) else {
                Self.respond(
                    failure: ServiceFailure.invalidRequest("not a session identifier"),
                    to: reply
                )
                return
            }
            let snapshot = await coordinator.leaseSnapshot(sessionID: identifier)
            Self.respond(with: snapshot, to: reply)
        }
    }

    func getLogSnapshot(
        sessionID: String,
        afterSequence: Int64,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        replyNotImplemented("getLogSnapshot", phase: 10, reply)
    }

    // MARK: - Replying

    /// Encodes a successful result, turning an encoding failure into a reported error rather
    /// than a silent empty reply.
    private static func respond<T: Encodable>(
        with value: T,
        to reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        // `encodeResponse` has typed throws, so the failure is already structured — there is
        // no untyped case left to translate.
        do {
            reply(try XPCPayload.encodeResponse(value), nil)
        } catch {
            reply(nil, error.asNSError)
        }
    }

    private static func respond(
        failure: any Error,
        to reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        if let serviceFailure = failure as? ServiceFailure {
            reply(nil, serviceFailure.asNSError)
        } else {
            reply(nil, ServiceFailure.internalError("\(failure)").asNSError)
        }
    }

    private func replyNotImplemented(
        _ name: String,
        phase: Int,
        _ reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        logger.error("\(name, privacy: .public) called before it is implemented")
        let failure = ServiceFailure(
            code: .internalError,
            title: "Not Available Yet",
            message: "This build of the privileged helper does not implement \(name).",
            recoverySuggestion: "Update MacNetLab to a build where this operation is available.",
            technicalDetails: "\(name) is implemented in phase \(phase)",
            isRetryable: false
        )
        reply(nil, failure.asNSError)
    }
}

/// Stands in for a reply with no payload.
///
/// The interface always answers with `(Data?, NSError?)`, and replying `(nil, nil)` would be
/// indistinguishable from a bug. An empty object says "this succeeded and had nothing to say".
struct EmptyReply: Codable, Sendable {}
