import Foundation

/// Compile-time facts about the shared core, used by the app and the helper to agree on
/// what they are talking to before any real work happens.
public enum MacNetCoreInfo: Sendable {
    /// XPC contract version. Must match `PROTOCOL_VERSION` in `Config/Identifiers.xcconfig`.
    /// The app refuses to drive a helper reporting a different value.
    public static let protocolVersion: Int = 1

    /// Schema version for every persisted document (profiles, session journal).
    public static let schemaVersion: Int = 1
}
