import Foundation

/// The complete XPC contract between the app and the privileged helper.
///
/// Design constraints this shape exists to satisfy:
///
/// * **Objective-C compatible.** NSXPCConnection requires an `@objc` protocol, so every
///   parameter is a plain `Data`, `String`, or `Int64`.
/// * **No free-form dictionaries.** Structured models are JSON-encoded into `Data` and
///   decoded into named types on the far side. The specification forbids `[String: Any]` as the
///   core protocol precisely because it invites "just one more key" and defeats validation.
/// * **No paths, no executables, no commands.** Nothing in this interface lets a caller name
///   a file to read, a binary to run, or a command to execute. Every path the helper touches
///   is derived by the helper from its own location and a UUID it generated itself.
/// * **Every reply is `(Data?, NSError?)`.** Failures cross as `NSError` carrying an encoded
///   `ServiceFailure`, so the app gets the same structured error the helper produced.
///
/// The whole protocol is declared here because it is the security boundary and is easier to
/// reason about as one piece; individual methods are implemented in the phase that owns them.
@objc public protocol DnsmasqForMacHelperProtocol {

    /// Identity and capability handshake. The app calls this first and refuses to proceed on
    /// a protocol mismatch or a non-root helper.
    func getServiceInfo(
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// Current runtime state, including any session already running — which is how the app
    /// recovers after being force-quit while services were up.
    func getRuntimeStatus(
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// Read-only validation of a proposed session. Must never change system state.
    func runPreflight(
        requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// Start a session as an all-or-nothing transaction.
    func startSession(
        requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// Stop the identified session and undo everything the app caused.
    func stopSession(
        sessionID: String,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// Current leases for the identified session.
    func getLeaseSnapshot(
        sessionID: String,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// Log lines after `afterSequence`, letting a reconnecting app resume without gaps or
    /// duplicates rather than re-reading the whole file.
    func getLogSnapshot(
        sessionID: String,
        afterSequence: Int64,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// Inspect the journal and clean up after a crash, without ever signalling a process
    /// whose identity cannot be confirmed.
    func recoverStaleState(
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
}

/// Helper-to-app push channel. Used for anything the app must learn about without polling:
/// state transitions, batched log lines, lease updates, and unexpected process death.
@objc public protocol DnsmasqForMacHelperClientProtocol {
    func helperDidEmitEvent(_ eventData: Data)
}

/// Kinds of event delivered over `DnsmasqForMacHelperClientProtocol`.
public enum HelperEventKind: String, Codable, Sendable {
    case runtimeStateChanged
    case logBatch
    case leaseSnapshot
    case unexpectedProcessExit
    case cleanupWarning
}

/// Envelope for a pushed event. The `kind` selects how `payload` is decoded, which keeps the
/// single-method callback interface from becoming an untyped grab bag.
public struct HelperEvent: Codable, Sendable, Equatable {
    public let kind: HelperEventKind
    public let payload: Data

    public init(kind: HelperEventKind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }
}

/// Builds the `NSXPCInterface` values for both directions.
///
/// Centralised so that the app and the helper cannot drift into configuring the same
/// interface differently — a mismatch there surfaces as an opaque runtime failure.
public enum HelperInterface {
    public static func makeServiceInterface() -> NSXPCInterface {
        NSXPCInterface(with: DnsmasqForMacHelperProtocol.self)
    }

    public static func makeClientInterface() -> NSXPCInterface {
        NSXPCInterface(with: DnsmasqForMacHelperClientProtocol.self)
    }
}
