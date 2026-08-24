import Foundation
import OSLog

/// Build-time identity of the helper, read from the Info.plist section embedded in the
/// executable. Nothing here is hardcoded; the values originate in
/// `Config/Identifiers.xcconfig` (ticket §3.1).
enum HelperIdentity {
    private static var info: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    static var bundleIdentifier: String {
        info["CFBundleIdentifier"] as? String ?? "com.bee.macnetlab.helper"
    }

    static var version: String {
        info["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var machServiceName: String {
        info["MNLMachServiceName"] as? String ?? bundleIdentifier
    }

    static var protocolVersion: Int {
        Int(info["MNLProtocolVersion"] as? String ?? "") ?? -1
    }

    /// Team identifier the caller's code signature must match.
    static var teamIdentifier: String? {
        info["MNLTeamIdentifier"] as? String
    }
}

/// Owns the helper's run loop.
///
/// Phase 2 attaches an `NSXPCListener` for the Mach service and the caller-validating
/// listener delegate. Until then this parks the process so that launchd's on-demand start
/// path can be exercised end to end.
final class HelperService: @unchecked Sendable {
    static let shared = HelperService()

    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "service")

    private init() {}

    func run() {
        logger.log("helper entering run loop on mach service \(HelperIdentity.machServiceName, privacy: .public)")
        // Replaced in Phase 2 by NSXPCListener(machServiceName:) plus its delegate.
        dispatchMain()
    }
}
