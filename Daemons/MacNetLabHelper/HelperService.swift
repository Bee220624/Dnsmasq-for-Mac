import Foundation
import MacNetModels
import MacNetXPC
import OSLog

/// Build-time identity of the helper, read from the Info.plist section embedded in the
/// executable. Nothing here is hardcoded; the values originate in
/// `Config/Identifiers.xcconfig` (ticket §3.1).
enum HelperIdentity {
    private static var info: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    private static func string(_ key: String) -> String? {
        (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var bundleIdentifier: String {
        string("CFBundleIdentifier") ?? "com.bee.macnetlab.helper"
    }

    static var version: String {
        string("CFBundleShortVersionString") ?? "0.0.0"
    }

    static var machServiceName: String? {
        string("MNLMachServiceName")
    }

    static var protocolVersion: Int {
        Int(string("MNLProtocolVersion") ?? "") ?? -1
    }

    /// Team identifier the caller's code signature must carry.
    static var teamIdentifier: String? {
        string("MNLTeamIdentifier")
    }

    /// Bundle identifier of the one app allowed to drive this helper, parsed out of the
    /// `SMAuthorizedClients` requirement the helper was built with. Deriving it from that
    /// single declaration keeps the runtime check and the launchd-visible declaration from
    /// drifting apart.
    static var authorizedAppBundleIdentifier: String? {
        guard let clients = info["SMAuthorizedClients"] as? [String],
              let requirement = clients.first
        else { return nil }

        // Extract X from: identifier "X" and anchor apple generic and ...
        guard let range = requirement.range(of: #"identifier "([^"]+)""#, options: .regularExpression)
        else { return nil }
        let matched = requirement[range]
        guard let open = matched.firstIndex(of: "\""),
              let close = matched.lastIndex(of: "\""),
              open < close
        else { return nil }
        let identifier = String(matched[matched.index(after: open)..<close])
        return identifier.isEmpty ? nil : identifier
    }

    static var buildType: HelperBuildType {
        #if DEBUG
        .debug
        #else
        .release
        #endif
    }
}

/// Owns the helper's XPC listener and run loop.
final class HelperService: @unchecked Sendable {
    static let shared = HelperService()

    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "service")

    private init() {}

    /// Starts serving. Does not return.
    ///
    /// Any failure to establish the security posture is fatal by design: a root helper that
    /// cannot identify its callers must not run at all (ticket §10.4).
    func run() -> Never {
        guard let machServiceName = HelperIdentity.machServiceName else {
            logger.fault("MNLMachServiceName missing from embedded Info.plist; build is corrupt")
            exit(EXIT_FAILURE)
        }

        // See CodeSigningRequirement for why the peer is pinned this way rather than by
        // UID, PID, executable name, or bundle path (ticket §10.4).
        guard let requirement = CodeSigningRequirement.forSignedProgram(
            bundleIdentifier: HelperIdentity.authorizedAppBundleIdentifier,
            teamIdentifier: HelperIdentity.teamIdentifier
        ) else {
            logger.fault(
                """
                cannot build a client code signing requirement; \
                embedded Info.plist is missing SMAuthorizedClients or MNLTeamIdentifier
                """
            )
            exit(EXIT_FAILURE)
        }

        let listener = NSXPCListener(machServiceName: machServiceName)

        // The system evaluates this against each peer's audit token before the delegate is
        // consulted, so an unverified caller never reaches our code (macOS 13+).
        listener.setConnectionCodeSigningRequirement(requirement)
        logger.log("client requirement in force: \(requirement, privacy: .public)")

        let delegate = HelperListenerDelegate(isRequirementEnforced: true)
        listener.delegate = delegate
        listener.resume()

        logger.log(
            """
            listening on \(machServiceName, privacy: .public) \
            version=\(HelperIdentity.version, privacy: .public) \
            protocol=\(HelperIdentity.protocolVersion, privacy: .public) \
            build=\(HelperIdentity.buildType.rawValue, privacy: .public)
            """
        )

        // Hold a strong reference for the process lifetime; `dispatchMain` never returns, so
        // the listener and delegate must not be deallocated on the way out of this scope.
        withExtendedLifetime((listener, delegate)) {
            dispatchMain()
        }
    }
}
