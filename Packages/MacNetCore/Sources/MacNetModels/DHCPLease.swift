import Foundation

/// Where a lease stands relative to now (ticket §5.4).
public enum LeaseStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case active
    case expired
    /// dnsmasq writes expiry `0` for a lease that never expires.
    case infinite
}

/// One entry from dnsmasq's lease file (ticket §18.2).
public struct DHCPLease: Codable, Sendable, Equatable, Identifiable {
    /// `<mac>|<ipv4>`.
    ///
    /// dnsmasq's lease file has no identifier column, and neither field alone is unique — one
    /// MAC can hold several addresses over time, and one address is reused across devices. The
    /// pair is what the table needs to keep rows stable as leases are renewed.
    public let id: String

    /// `nil` for an infinite lease.
    public let expiresAt: Date?
    /// Normalized to lowercase, colon-separated.
    public let macAddress: String
    public let ipv4Address: IPv4Address
    /// `nil` when the client sent no hostname; dnsmasq writes `*`.
    public let hostname: String?
    /// `nil` when absent; dnsmasq writes `*`.
    public let clientID: String?
    public let status: LeaseStatus

    public init(
        expiresAt: Date?,
        macAddress: String,
        ipv4Address: IPv4Address,
        hostname: String?,
        clientID: String?,
        status: LeaseStatus
    ) {
        id = "\(macAddress)|\(ipv4Address)"
        self.expiresAt = expiresAt
        self.macAddress = macAddress
        self.ipv4Address = ipv4Address
        self.hostname = hostname
        self.clientID = clientID
        self.status = status
    }

    /// Time left, or `nil` for an infinite or already-expired lease.
    ///
    /// Computed from a passed-in `now` rather than reading the clock, so the UI can tick every
    /// second without re-reading the lease file (ticket §5.4) and so this stays testable.
    public func remaining(asOf now: Date) -> TimeInterval? {
        guard status == .active, let expiresAt else { return nil }
        let interval = expiresAt.timeIntervalSince(now)
        return interval > 0 ? interval : nil
    }
}
