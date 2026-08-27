import Foundation

/// How a log line is classified for filtering.
///
/// Five buckets rather than free-form levels, because the question a user has in front of a
/// non-booting device is "is DHCP happening at all", and that is answered by filtering to one
/// category — not by reading severity.
public enum LogCategory: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case system
    case dhcp
    case dns
    case warning
    case error

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: "System"
        case .dhcp: "DHCP"
        case .dns: "DNS"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    /// SF Symbol for the category chip.
    public var systemImage: String {
        switch self {
        case .system: "gearshape"
        case .dhcp: "arrow.left.arrow.right"
        case .dns: "globe"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

/// One line of dnsmasq output, as delivered to the app.
public struct LogEvent: Codable, Sendable, Equatable, Identifiable {
    /// Same value as `sequence`. Present because SwiftUI's `List` needs `Identifiable`, and
    /// the sequence number already is a stable identity.
    public var id: Int64 { sequence }

    /// Monotonic within a session.
    ///
    /// This is what makes reconnection exact rather than approximate: the app asks for
    /// everything after the highest sequence it has, so it gets no gaps and no duplicates
    ///.
    public let sequence: Int64

    /// When the helper read the line, not when dnsmasq wrote it.
    ///
    /// dnsmasq's own timestamps have no year and no time zone, so reconstructing an absolute
    /// time from them is guesswork. The read time is a fact, and for a live log it is within
    /// milliseconds of the truth anyway.
    public let timestamp: Date

    public let category: LogCategory
    public let message: String

    public init(sequence: Int64, timestamp: Date, category: LogCategory, message: String) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}
