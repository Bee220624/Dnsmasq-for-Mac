import Foundation

/// How the helper was compiled. Surfaced in the UI because a helper built with the relaxed
/// development security policy must never be mistaken for a release one.
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

    /// What the helper found when it checked the bundled dnsmasq, or `nil` if the check
    /// failed.
    ///
    /// Reported by the helper rather than read from the app's own compiled constants: Settings
    /// should show what the process that will actually run it sees, not what the app was built
    /// believing. A `nil` here means the engine did not verify, and no session can start.
    public let engineVerification: EngineVerification?

    /// A summary of the bundled dnsmasq.
    public struct EngineVerification: Codable, Sendable, Equatable {
        public let version: String
        public let sha256: String
        public let architectures: String
        /// The `Compile time options:` line from `--version`.
        public let compileOptions: String

        public init(
            version: String, sha256: String, architectures: String, compileOptions: String
        ) {
            self.version = version
            self.sha256 = sha256
            self.architectures = architectures
            self.compileOptions = compileOptions
        }
    }

    public init(
        helperVersion: String,
        protocolVersion: Int,
        effectiveUID: UInt32,
        buildType: HelperBuildType,
        bundleIdentifier: String,
        engineVerification: EngineVerification? = nil
    ) {
        self.helperVersion = helperVersion
        self.protocolVersion = protocolVersion
        self.effectiveUID = effectiveUID
        self.buildType = buildType
        self.bundleIdentifier = bundleIdentifier
        self.engineVerification = engineVerification
    }

    /// True when this helper is safe for the app to drive.
    public func isCompatible(withProtocolVersion appProtocolVersion: Int) -> Bool {
        protocolVersion == appProtocolVersion && effectiveUID == 0
    }
}
