import Foundation

/// Hard size limits on anything crossing the XPC boundary (ticket §7.10).
///
/// These are enforced by the receiver, not merely respected by the sender: an oversized
/// payload is refused before it is decoded, so a hostile client cannot make the root helper
/// allocate unbounded memory or spend time parsing attacker-controlled JSON.
public enum XPCLimits {
    /// Maximum size of a request from the app to the helper.
    public static let maximumRequestBytes = 1 * 1024 * 1024      // 1 MiB

    /// Maximum size of a response from the helper to the app.
    public static let maximumResponseBytes = 4 * 1024 * 1024     // 4 MiB
}
