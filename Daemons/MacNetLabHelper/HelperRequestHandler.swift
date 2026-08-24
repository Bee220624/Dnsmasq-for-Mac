import Foundation
import MacNetModels
import MacNetXPC
import OSLog

/// The object exported to a verified client — the helper's entire externally reachable
/// surface (ticket §10.5).
///
/// Every method here is a fixed, named operation. There is deliberately no way for a caller
/// to name a command, an executable, or a path: the operations that need them derive them
/// from the helper's own location and from identifiers the helper generated itself.
///
/// Methods land here phase by phase. Anything not yet implemented answers with a structured
/// failure rather than silently succeeding, so a premature call is unmistakable.
final class HelperRequestHandler: NSObject, MacNetLabHelperProtocol {

    private let logger = Logger(
        subsystem: HelperIdentity.bundleIdentifier,
        category: "requests"
    )

    // MARK: - Implemented

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

        do {
            reply(try XPCPayload.encodeResponse(info), nil)
        } catch let failure as ServiceFailure {
            reply(nil, failure.asNSError)
        } catch {
            reply(nil, ServiceFailure.internalError("\(error)").asNSError)
        }
    }

    // MARK: - Awaiting their phase

    func getRuntimeStatus(withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        replyNotImplemented("getRuntimeStatus", phase: 8, reply)
    }

    func runPreflight(
        requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        replyNotImplemented("runPreflight", phase: 8, reply)
    }

    func startSession(
        requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        replyNotImplemented("startSession", phase: 8, reply)
    }

    func stopSession(
        sessionID: String,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        replyNotImplemented("stopSession", phase: 8, reply)
    }

    func getLeaseSnapshot(
        sessionID: String,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        replyNotImplemented("getLeaseSnapshot", phase: 9, reply)
    }

    func getLogSnapshot(
        sessionID: String,
        afterSequence: Int64,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        replyNotImplemented("getLogSnapshot", phase: 10, reply)
    }

    func recoverStaleState(withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        replyNotImplemented("recoverStaleState", phase: 8, reply)
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
