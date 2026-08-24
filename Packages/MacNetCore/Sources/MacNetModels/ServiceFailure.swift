import Foundation

/// Every way a MacNetLab operation can fail, as a closed set (ticket §6.10).
///
/// Closed rather than free-form because the UI maps each case to a specific recovery
/// affordance, and because an error crossing the XPC boundary must survive encoding without
/// losing meaning.
public enum ServiceErrorCode: String, Codable, Sendable, CaseIterable {
    // Helper availability and identity.
    case helperUnavailable
    case helperAuthorizationRequired
    case helperVersionMismatch
    case unauthorizedClient

    // Request shape.
    case invalidRequest
    case payloadTooLarge

    // Interface selection.
    case interfaceNotFound
    case interfaceNotSupported
    case interfaceIsDefaultRoute
    case interfaceIsWiFi

    // Addressing.
    case invalidServerAddress
    case invalidDHCPRange
    case invalidDNSConfiguration

    // Environment.
    case portInUse

    // Bundled engine.
    case dnsmasqMissing
    case dnsmasqHashMismatch
    case dnsmasqConfigInvalid

    // Session lifecycle.
    case aliasConfigurationFailed
    case processStartFailed
    case processExited
    case processStopFailed
    case cleanupFailed
    case staleSession

    case internalError
}

/// A failure as presented to the user: an identifying code plus text that is already fit to
/// display. Carrying the presentation with the error keeps the helper — which knows what
/// actually went wrong — in charge of describing it, instead of the UI guessing from a code.
public struct ServiceFailure: Codable, Sendable, Equatable, Error {
    public let code: ServiceErrorCode
    public let title: String
    public let message: String
    public let recoverySuggestion: String?
    /// Diagnostic detail such as an exit status or the tail of a log. Shown behind a
    /// disclosure, never as the primary message.
    public let technicalDetails: String?
    /// Whether repeating the identical request could plausibly succeed. Drives whether the
    /// UI offers Retry; a validation failure is not retryable, a busy lock is.
    public let isRetryable: Bool

    public init(
        code: ServiceErrorCode,
        title: String,
        message: String,
        recoverySuggestion: String? = nil,
        technicalDetails: String? = nil,
        isRetryable: Bool = false
    ) {
        self.code = code
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.technicalDetails = technicalDetails
        self.isRetryable = isRetryable
    }
}

// MARK: - NSError bridging

/// The XPC interface is Objective-C, so failures travel as `NSError`. The full structured
/// failure rides along in `userInfo` and is recovered on the far side; the localized fields
/// are also populated so that an `NSError` logged by the system is still readable.
extension ServiceFailure {
    public static let errorDomain = "com.bee.macnetlab.ServiceFailure"
    static let payloadUserInfoKey = "com.bee.macnetlab.ServiceFailure.payload"

    public var asNSError: NSError {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: title,
            NSLocalizedFailureReasonErrorKey: message,
        ]
        if let recoverySuggestion {
            userInfo[NSLocalizedRecoverySuggestionErrorKey] = recoverySuggestion
        }
        // Encoding cannot fail for this type — every stored property is a String or Bool —
        // but a `try?` keeps the bridge total rather than trapping on the error path, which
        // is the worst possible place to crash.
        if let payload = try? JSONEncoder().encode(self) {
            userInfo[Self.payloadUserInfoKey] = payload
        }
        return NSError(
            domain: Self.errorDomain,
            code: Self.numericCode(for: code),
            userInfo: userInfo
        )
    }

    /// Recovers the structured failure from an `NSError` produced by `asNSError`.
    ///
    /// Returns `nil` for anything else — an XPC transport error, for instance — so the caller
    /// can tell "the helper reported a problem" apart from "the connection broke", which need
    /// different handling.
    public static func from(nsError: NSError) -> ServiceFailure? {
        guard nsError.domain == errorDomain,
              let payload = nsError.userInfo[payloadUserInfoKey] as? Data
        else { return nil }
        return try? JSONDecoder().decode(ServiceFailure.self, from: payload)
    }

    private static func numericCode(for code: ServiceErrorCode) -> Int {
        (ServiceErrorCode.allCases.firstIndex(of: code) ?? 0) + 1
    }
}

// MARK: - Common failures

extension ServiceFailure {
    public static func internalError(_ details: String) -> ServiceFailure {
        ServiceFailure(
            code: .internalError,
            title: "Internal Error",
            message: "MacNetLab encountered an unexpected internal error.",
            recoverySuggestion: "Try the operation again. If it keeps happening, restart the app.",
            technicalDetails: details,
            isRetryable: true
        )
    }

    public static func invalidRequest(_ details: String) -> ServiceFailure {
        ServiceFailure(
            code: .invalidRequest,
            title: "Invalid Request",
            message: "The request was rejected because it did not pass validation.",
            recoverySuggestion: "Check the configuration values and try again.",
            technicalDetails: details,
            isRetryable: false
        )
    }

    public static func payloadTooLarge(byteCount: Int, limit: Int) -> ServiceFailure {
        ServiceFailure(
            code: .payloadTooLarge,
            title: "Request Too Large",
            message: "The request exceeded the maximum size accepted by the privileged helper.",
            recoverySuggestion: "Reduce the number of local DNS records and try again.",
            technicalDetails: "payload was \(byteCount) bytes, limit is \(limit) bytes",
            isRetryable: false
        )
    }

    public static let unauthorizedClient = ServiceFailure(
        code: .unauthorizedClient,
        title: "Unauthorized Client",
        message: "The privileged helper rejected this connection because the caller could not be verified.",
        recoverySuggestion: "Reinstall MacNetLab from your original download and try again.",
        technicalDetails: nil,
        isRetryable: false
    )
}
