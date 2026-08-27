import Foundation

/// Absolute paths for one session's runtime files.
///
/// Every path here is derived by the **helper** from its own location and a UUID the helper
/// generated. The specification forbid the app from supplying any path, and the specification
/// requires session directories to be named from a UUID rather than from a profile name,
/// hostname, or interface name — none of which are under our control and all of which could
/// contain a path separator.
///
/// This type is passed *into* the generator so that the generator itself never touches the
/// file system and stays a pure function.
public struct RuntimePaths: Sendable, Equatable {
    /// Directory holding everything for this session.
    public let sessionDirectory: String

    public init(sessionDirectory: String) {
        self.sessionDirectory = sessionDirectory
    }

    /// Builds the standard layout for a session under the helper's runtime root.
    ///
    /// Takes a `UUID` rather than a `String` so that a caller cannot pass an arbitrary
    /// directory component at all — the type makes path traversal unrepresentable rather than
    /// merely rejected.
    public init(runtimeRoot: String, sessionID: UUID) {
        sessionDirectory = "\(runtimeRoot)/sessions/\(sessionID.uuidString)"
    }

    public var configurationFile: String { "\(sessionDirectory)/dnsmasq.conf" }
    public var hostsFile: String { "\(sessionDirectory)/hosts" }
    public var leaseFile: String { "\(sessionDirectory)/dnsmasq.leases" }
    public var logFile: String { "\(sessionDirectory)/dnsmasq.log" }
    public var pidFile: String { "\(sessionDirectory)/dnsmasq.pid" }

    /// Rotated log files, oldest last. At most three are kept.
    public func rotatedLogFile(index: Int) -> String { "\(logFile).\(index)" }
}
