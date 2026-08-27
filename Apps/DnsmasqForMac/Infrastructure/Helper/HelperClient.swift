import Foundation
import MacNetModels
import MacNetXPC
import OSLog
import ServiceManagement

/// Owns the app's relationship with the privileged helper: registration through
/// `SMAppService`, the XPC connection, and the identity handshake.
///
/// An `actor` because the connection and its state are shared mutable state touched from
/// several places — status polling, user-initiated install, and request calls.
actor HelperClient {

    private let logger = Logger(subsystem: "com.bee.dnsmasqformac", category: "helper-client")

    private let daemonPlistName: String
    private let machServiceName: String
    private let expectedProtocolVersion: Int
    private let helperRequirement: String?

    private var connection: NSXPCConnection?

    init(environment: AppEnvironment) {
        // SMAppService identifies the daemon by the plist's file name inside
        // Contents/Library/LaunchDaemons, which Scripts/embed-helper.sh names after the label.
        daemonPlistName = "\(environment.helperLabel).plist"
        machServiceName = environment.machServiceName
        expectedProtocolVersion = environment.protocolVersion
        // Same builder the helper uses to pin us, so the two directions cannot drift.
        helperRequirement = CodeSigningRequirement.forSignedProgram(
            bundleIdentifier: environment.helperLabel,
            teamIdentifier: environment.teamIdentifier
        )
    }

    // MARK: - Installation

    private var appService: SMAppService {
        SMAppService.daemon(plistName: daemonPlistName)
    }

    func installationState() -> HelperInstallationState {
        HelperInstallationState(status: appService.status)
    }

    /// Registers the daemon with the system.
    ///
    /// A `requiresApproval` outcome is a normal, expected result, not an error: macOS is
    /// waiting for the user to enable the item in System Settings. The specification forbids
    /// retrying `register()` in a loop to force it through.
    func install() throws(ServiceFailure) -> HelperInstallationState {
        do {
            try appService.register()
            logger.log("SMAppService.register succeeded")
        } catch {
            let nsError = error as NSError
            logger.error("SMAppService.register failed: \(nsError, privacy: .public)")

            // kSMErrorAlreadyRegistered. Registering an already-registered daemon is not a
            // problem; report the real status instead of a spurious failure.
            if nsError.code == 3 {
                return installationState()
            }

            throw ServiceFailure(
                code: .helperUnavailable,
                title: "Could Not Install Helper",
                message: "macOS refused to register the privileged helper.",
                recoverySuggestion:
                    "Make sure Dnsmasq for Mac is in your Applications folder, then try again.",
                technicalDetails: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)",
                isRetryable: true
            )
        }
        return installationState()
    }

    /// Unregisters the daemon. Callers must ensure no session is running first — the specification
    /// forbids uninstalling the helper while services are up.
    func uninstall() async throws(ServiceFailure) {
        closeConnection()
        do {
            try await appService.unregister()
            logger.log("SMAppService.unregister succeeded")
        } catch {
            let nsError = error as NSError
            throw ServiceFailure(
                code: .helperUnavailable,
                title: "Could Not Remove Helper",
                message: "macOS refused to unregister the privileged helper.",
                recoverySuggestion:
                    "Open System Settings › General › Login Items & Extensions and remove it there.",
                technicalDetails: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)",
                isRetryable: true
            )
        }
    }

    /// Opens the Login Items pane so the user can approve the daemon.
    nonisolated func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Connection

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }

        let created = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        created.remoteObjectInterface = HelperInterface.makeServiceInterface()

        // Mutual authentication: the helper pins the app, and here the app pins the helper,
        // so a hostile process cannot impersonate the service we are about to trust with
        // root operations (macOS 13+).
        if let helperRequirement {
            created.setCodeSigningRequirement(helperRequirement)
        }

        // Accept pushed events from the helper.
        created.exportedInterface = HelperInterface.makeClientInterface()
        created.exportedObject = HelperEventReceiver()

        // Explicitly @Sendable: these run on XPC's own queue, not on this actor, so the
        // closures must not inherit actor isolation. Hopping back in via Task keeps all
        // mutation of `connection` on the actor.
        created.invalidationHandler = { @Sendable [weak self] in
            Task { await self?.handleConnectionDropped(reason: "invalidated") }
        }
        created.interruptionHandler = { @Sendable [weak self] in
            Task { await self?.handleConnectionDropped(reason: "interrupted") }
        }

        created.resume()
        connection = created
        return created
    }

    private func handleConnectionDropped(reason: String) {
        logger.log("helper connection \(reason, privacy: .public)")
        connection = nil
    }

    func closeConnection() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Handshake

    /// Connects and asks the helper who it is, then decides whether it is usable.
    func handshake() async -> HelperReadiness {
        let state = installationState()
        guard state.isConnectable else {
            return .notInstalled(state)
        }

        do {
            let info = try await getServiceInfo()
            let snapshot = HelperServiceInfoSnapshot(info)

            guard info.effectiveUID == 0 else {
                return .incompatible(
                    snapshot,
                    reason: "The helper is not running with root privileges."
                )
            }
            guard info.protocolVersion == expectedProtocolVersion else {
                return .incompatible(
                    snapshot,
                    reason: "The helper speaks protocol \(info.protocolVersion), "
                        + "but this app requires protocol \(expectedProtocolVersion)."
                )
            }
            return .ready(snapshot)
        } catch {
            return .failed(error)
        }
    }

    func getServiceInfo() async throws(ServiceFailure) -> HelperServiceInfo {
        let data = try await withProxy { proxy, box in
            proxy.getServiceInfo { data, error in
                box.resume(with: HelperClient.result(data: data, error: error))
            }
        }
        // Typed throws: the failure is already structured, so there is nothing to translate.
        return try XPCPayload.decodeResponse(HelperServiceInfo.self, from: data)
    }

    // MARK: - Session lifecycle

    func runtimeStatus() async throws(ServiceFailure) -> RuntimeState {
        try await call(RuntimeState.self) { proxy, box in
            proxy.getRuntimeStatus { data, error in
                box.resume(with: HelperClient.result(data: data, error: error))
            }
        }
    }

    func preflight(
        _ request: SessionStartRequest
    ) async throws(ServiceFailure) -> PreflightReport {
        let payload = try XPCPayload.encodeRequest(request)
        return try await call(PreflightReport.self) { proxy, box in
            proxy.runPreflight(requestData: payload) { data, error in
                box.resume(with: HelperClient.result(data: data, error: error))
            }
        }
    }

    func startSession(
        _ request: SessionStartRequest
    ) async throws(ServiceFailure) -> ActiveSession {
        let payload = try XPCPayload.encodeRequest(request)
        return try await call(ActiveSession.self) { proxy, box in
            proxy.startSession(requestData: payload) { data, error in
                box.resume(with: HelperClient.result(data: data, error: error))
            }
        }
    }

    func stopSession(id: UUID) async throws(ServiceFailure) {
        _ = try await call(EmptyHelperReply.self) { proxy, box in
            proxy.stopSession(sessionID: id.uuidString) { data, error in
                box.resume(with: HelperClient.result(data: data, error: error))
            }
        }
    }

    func leaseSnapshot(sessionID: UUID) async throws(ServiceFailure) -> LeaseSnapshot {
        try await call(LeaseSnapshot.self) { proxy, box in
            proxy.getLeaseSnapshot(sessionID: sessionID.uuidString) { data, error in
                box.resume(with: HelperClient.result(data: data, error: error))
            }
        }
    }

    func logSnapshot(
        sessionID: UUID,
        after sequence: Int64
    ) async throws(ServiceFailure) -> LogBatch {
        try await call(LogBatch.self) { proxy, box in
            proxy.getLogSnapshot(
                sessionID: sessionID.uuidString, afterSequence: sequence
            ) { data, error in
                box.resume(with: HelperClient.result(data: data, error: error))
            }
        }
    }

    func recoverStaleState() async throws(ServiceFailure) -> RecoveryReport {
        try await call(RecoveryReport.self) { proxy, box in
            proxy.recoverStaleState { data, error in
                box.resume(with: HelperClient.result(data: data, error: error))
            }
        }
    }

    // MARK: - Call plumbing

    /// Runs one XPC call and decodes its reply.
    ///
    /// Wraps `withProxy` so that every call site is one expression rather than a repeated
    /// encode–call–decode dance, and so decoding failures are classified once.
    private func call<T: Decodable>(
        _ type: T.Type,
        _ body: @escaping @Sendable (any DnsmasqForMacHelperProtocol, ContinuationBox) -> Void
    ) async throws(ServiceFailure) -> T {
        let data = try await withProxy(body)
        return try XPCPayload.decodeResponse(type, from: data)
    }


    /// Bridges one `(Data?, NSError?)` XPC callback into an `async` call.
    ///
    /// The proxy's error handler and the reply block are mutually exclusive but neither is
    /// guaranteed, so the continuation is guarded to make a double resume — which would trap
    /// — impossible even if XPC misbehaves.
    private func withProxy(
        _ body: @escaping @Sendable (any DnsmasqForMacHelperProtocol, ContinuationBox) -> Void
    ) async throws(ServiceFailure) -> Data {
        let connection = activeConnection()

        do {
            return try await withCheckedThrowingContinuation { continuation in
                let box = ContinuationBox(continuation)

                // Both the error handler and the reply block route through `box`, which
                // resumes at most once. XPC guarantees only one of them fires, but a double
                // resume traps the process, so the invariant is enforced rather than assumed.
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    box.resume(
                        with: .failure(HelperClient.transportFailure(from: error as NSError))
                    )
                }

                guard let helper = proxy as? any DnsmasqForMacHelperProtocol else {
                    box.resume(with: .failure(ServiceFailure.internalError(
                        "helper proxy does not conform to DnsmasqForMacHelperProtocol"
                    )))
                    return
                }

                body(helper, box)
            }
        } catch let failure as ServiceFailure {
            throw failure
        } catch {
            throw ServiceFailure.internalError("unexpected XPC error: \(error)")
        }
    }

    private static func result(data: Data?, error: NSError?) -> Result<Data, any Error> {
        if let error {
            return .failure(ServiceFailure.from(nsError: error) ?? transportFailure(from: error))
        }
        guard let data else {
            return .failure(
                ServiceFailure.internalError("helper replied with neither data nor an error")
            )
        }
        return .success(data)
    }

    /// Classifies an `NSError` that did not carry a `ServiceFailure` — i.e. the channel
    /// failed rather than the operation.
    private static func transportFailure(from error: NSError) -> ServiceFailure {
        ServiceFailure(
            code: .helperUnavailable,
            title: "Helper Unavailable",
            message: "Dnsmasq for Mac could not communicate with its privileged helper.",
            recoverySuggestion:
                "Open Settings and choose Install or Repair Helper, then try again.",
            technicalDetails: "\(error.domain) \(error.code): \(error.localizedDescription)",
            isRetryable: true
        )
    }

}

/// Ensures a continuation is resumed exactly once.
///
/// Resuming a `CheckedContinuation` twice traps, and the two callbacks XPC gives us — the
/// reply block and the proxy's error handler — are only *documented* to be mutually
/// exclusive. Enforcing it here costs a lock and removes a whole class of crash.
final class ContinuationBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<Data, any Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Data, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// Receives pushed events from the helper. Wired up now so the bidirectional channel is
/// proven end to end; the events themselves are consumed by the lease and log monitors.
private final class HelperEventReceiver: NSObject, DnsmasqForMacHelperClientProtocol {
    private let logger = Logger(subsystem: "com.bee.dnsmasqformac", category: "helper-events")

    func helperDidEmitEvent(_ eventData: Data) {
        logger.debug("received helper event, \(eventData.count, privacy: .public) bytes")
    }
}

/// Mirrors the helper's empty-reply payload.
///
/// The XPC interface always answers with `(Data?, NSError?)`, so "succeeded with nothing to
/// say" needs a shape. Decoding it — rather than ignoring the data — keeps a malformed reply
/// from being read as success.
struct EmptyHelperReply: Codable, Sendable {}
