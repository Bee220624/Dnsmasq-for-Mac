import Foundation
import MacNetModels
import ServiceManagement

/// What the app knows about the helper's installation, as one value.
///
/// Each case maps to exactly one thing the user can do about it, which is what keeps the
/// onboarding flow from turning into a pile of booleans (ticket §10.2).
enum HelperInstallationState: Equatable, Sendable {
    /// Never registered on this machine. Offer Install.
    case notRegistered

    /// Registered, but macOS is waiting for the user to approve it in System Settings.
    /// Ticket §10.2 forbids looping on `register()` here: the app shows the steps and waits.
    case requiresApproval

    /// Registered and approved. The Mach service can be reached.
    case enabled

    /// macOS cannot find the daemon plist inside the app bundle, which means the bundle was
    /// built or copied incorrectly rather than anything the user did wrong.
    case bundleIncomplete

    /// `SMAppService` reported a status this build does not know how to interpret.
    case unknown(rawValue: Int)

    init(status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .bundleIncomplete
        @unknown default: self = .unknown(rawValue: status.rawValue)
        }
    }

    /// Whether it is worth attempting an XPC connection.
    var isConnectable: Bool { self == .enabled }
}

/// The app's overall readiness to drive the helper: installation state plus, once connected,
/// what the helper said about itself.
enum HelperReadiness: Equatable, Sendable {
    case checking
    case notInstalled(HelperInstallationState)
    case connecting
    /// Connected, handshake complete, versions agree.
    case ready(HelperServiceInfoSnapshot)
    /// Connected but unusable — a protocol mismatch or a helper that is not root.
    case incompatible(HelperServiceInfoSnapshot, reason: String)
    case failed(ServiceFailure)
}

/// UI-facing copy of the helper's identity. Kept separate from the wire model so that view
/// code never holds a type whose shape is dictated by the XPC contract.
struct HelperServiceInfoSnapshot: Equatable, Sendable {
    let helperVersion: String
    let protocolVersion: Int
    let effectiveUID: UInt32
    let isDebugBuild: Bool
    let bundleIdentifier: String
    /// What the helper found when it checked the bundled dnsmasq. `nil` means it did not
    /// verify — which the UI must show plainly, because no session can start.
    let engine: HelperServiceInfo.EngineVerification?

    init(_ info: HelperServiceInfo) {
        helperVersion = info.helperVersion
        protocolVersion = info.protocolVersion
        effectiveUID = info.effectiveUID
        isDebugBuild = info.buildType == .debug
        bundleIdentifier = info.bundleIdentifier
        engine = info.engineVerification
    }
}
