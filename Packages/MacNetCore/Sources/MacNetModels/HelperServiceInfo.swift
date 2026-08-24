import Foundation

/// How the helper was compiled. Surfaced in the UI because a helper built with the relaxed
/// development security policy must never be mistaken for a release one (ticket §10.4).
public enum HelperBuildType: String, Codable, Sendable {
    case release
    case debug
}

/// The helper's answer to "who are you, and can we work together?".
///
/// This is the first call the app makes after connecting, and its result gates everything
/// else: a protocol mismatch or a non-root helper means no session may be attempted.
public struct HelperServiceInfo: Codable, Sendable, Equatable {
    /// Helper's marketing version, e.g. `0.1.0`.
    public let helperVersion: String

    /// XPC contract version the helper speaks. Must equal the app's own.
    public let protocolVersion: Int

    /// Effective UID of the helper process. Anything other than 0 means the helper is not
    /// privileged and cannot do its job, which the app reports rather than discovering later
    /// through a confusing permission failure.
    public let effectiveUID: UInt32

    public let buildType: HelperBuildType

    /// Bundle identifier the helper was built with, so a mismatched pairing is visible.
    public let bundleIdentifier: String

    public init(
        helperVersion: String,
        protocolVersion: Int,
        effectiveUID: UInt32,
        buildType: HelperBuildType,
        bundleIdentifier: String
    ) {
        self.helperVersion = helperVersion
        self.protocolVersion = protocolVersion
        self.effectiveUID = effectiveUID
        self.buildType = buildType
        self.bundleIdentifier = bundleIdentifier
    }

    /// True when this helper is safe for the app to drive.
    public func isCompatible(withProtocolVersion appProtocolVersion: Int) -> Bool {
        protocolVersion == appProtocolVersion && effectiveUID == 0
    }
}
