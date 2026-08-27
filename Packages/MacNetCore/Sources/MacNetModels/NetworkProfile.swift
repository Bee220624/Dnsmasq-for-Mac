import Foundation

/// A saved, reusable configuration (ticket §6.1).
///
/// A profile describes *what* to serve, never *where*: it carries no interface identity. That
/// is deliberate — see `InterfaceConfiguration`.
public struct NetworkProfile: Codable, Sendable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID

    public var name: String

    public var interfaceConfiguration: InterfaceConfiguration
    public var dhcpConfiguration: DHCPConfiguration
    public var dnsConfiguration: DNSConfiguration

    public let createdAt: Date

    /// Normalized on every assignment, not only in `init`.
    ///
    /// Callers naturally write `profile.updatedAt = Date()`, which would reintroduce
    /// sub-second precision and break the save verification described in
    /// `Date.truncatedToSeconds`. Enforcing it here means no call site has to remember.
    /// Assigning inside an observer does not re-enter it.
    public var updatedAt: Date {
        didSet { updatedAt = updatedAt.truncatedToSeconds }
    }

    public init(
        schemaVersion: Int = MacNetCoreInfo.schemaVersion,
        id: UUID = UUID(),
        name: String,
        interfaceConfiguration: InterfaceConfiguration,
        dhcpConfiguration: DHCPConfiguration,
        dnsConfiguration: DNSConfiguration,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.interfaceConfiguration = interfaceConfiguration
        self.dhcpConfiguration = dhcpConfiguration
        self.dnsConfiguration = dnsConfiguration
        // Normalized here so the invariant holds however a profile is constructed: a
        // timestamp that cannot be represented in the persisted format would make every
        // save's read-back verification fail. See Date.truncatedToSeconds.
        self.createdAt = createdAt.truncatedToSeconds
        self.updatedAt = updatedAt.truncatedToSeconds
    }
}

/// Addressing for the Mac itself while a session runs (ticket §6.2).
///
/// Note what is **not** here: any reference to `en7` or any other BSD name. Ticket §6.2 is
/// explicit that a profile must not bind to an interface, for three reasons — a USB adapter's
/// BSD name changes between reboots and ports, the same profile on another Mac would name a
/// different interface, and an automatic binding could silently select a production port. The
/// most recently used interface is remembered in `UserDefaults` as a convenience, and the user
/// still confirms it before every start.
public struct InterfaceConfiguration: Codable, Sendable, Equatable {
    /// Whether to add a temporary IPv4 alias to the selected interface on start. When false,
    /// the interface is expected to already carry `serverIPv4`.
    public var addTemporaryIPv4Alias: Bool
    public var serverIPv4: IPv4Address
    public var prefixLength: Int

    public init(addTemporaryIPv4Alias: Bool, serverIPv4: IPv4Address, prefixLength: Int) {
        self.addTemporaryIPv4Alias = addTemporaryIPv4Alias
        self.serverIPv4 = serverIPv4
        self.prefixLength = prefixLength
    }

    /// The subnet implied by this configuration, or `nil` if the prefix length is out of
    /// range. Validation reports that properly; this accessor simply does not guess.
    public var subnet: IPv4Subnet? {
        IPv4Subnet(containing: serverIPv4, prefixLength: prefixLength)
    }
}

/// DHCPv4 server settings (ticket §6.3).
public struct DHCPConfiguration: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var rangeStart: IPv4Address
    public var rangeEnd: IPv4Address
    public var leaseDurationSeconds: Int

    /// Answer requests this server has no lease for. dnsmasq's own documentation warns this
    /// is only safe when it is the sole DHCP server on the network, which is why the UI keeps
    /// it behind a disclosure with that warning attached (ticket §5.3.3).
    public var authoritative: Bool

    /// Whether to send a default gateway to clients. Off by default: Dnsmasq for Mac provides no
    /// NAT or IP forwarding, so a router option usually points at nothing.
    public var advertiseRouter: Bool
    public var routerIPv4: IPv4Address?

    /// Whether to tell clients to use this Mac for DNS.
    public var advertiseLocalDNSServer: Bool

    public init(
        enabled: Bool,
        rangeStart: IPv4Address,
        rangeEnd: IPv4Address,
        leaseDurationSeconds: Int,
        authoritative: Bool,
        advertiseRouter: Bool,
        routerIPv4: IPv4Address?,
        advertiseLocalDNSServer: Bool
    ) {
        self.enabled = enabled
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.leaseDurationSeconds = leaseDurationSeconds
        self.authoritative = authoritative
        self.advertiseRouter = advertiseRouter
        self.routerIPv4 = routerIPv4
        self.advertiseLocalDNSServer = advertiseLocalDNSServer
    }

    /// Lease durations offered in the UI (ticket §5.3.3). Stored as seconds.
    public static let leaseDurationPresets: [Int] = [
        600,      // 10 minutes
        3_600,    // 1 hour
        28_800,   // 8 hours
        43_200,   // 12 hours
        86_400,   // 24 hours
        604_800,  // 7 days
    ]

    /// Permitted lease duration range (ticket §7.5): 2 minutes to 7 days.
    public static let allowedLeaseDurationSeconds: ClosedRange<Int> = 120...604_800

    /// Largest pool v0.1 will serve (ticket §7.4). A bench network needs nothing near this,
    /// and an unbounded pool on a mistyped prefix would be a very effective way to disrupt a
    /// real network.
    public static let maximumPoolSize: UInt32 = 1024

    /// Number of addresses in the pool, or `nil` when the range is inverted.
    public var poolSize: UInt32? {
        rangeStart.addressCount(through: rangeEnd)
    }
}

/// Where DNS queries that are not answered locally should go (ticket §6.4).
public enum DNSUpstreamMode: String, Codable, Sendable, CaseIterable {
    /// Snapshot the Mac's own resolvers at start.
    case system
    /// Use an explicit list.
    case custom
    /// Answer only local records and DHCP hostnames. External lookups failing is the point,
    /// not a defect — it is how you prove a device is talking to this server and nothing else.
    case localOnly
}

/// DNS server settings (ticket §6.4).
public struct DNSConfiguration: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var localDomain: String
    public var upstreamMode: DNSUpstreamMode
    public var customUpstreamServers: [IPv4Address]
    public var logQueries: Bool
    public var records: [LocalDNSRecord]

    public init(
        enabled: Bool,
        localDomain: String,
        upstreamMode: DNSUpstreamMode,
        customUpstreamServers: [IPv4Address],
        logQueries: Bool,
        records: [LocalDNSRecord]
    ) {
        self.enabled = enabled
        self.localDomain = localDomain
        self.upstreamMode = upstreamMode
        self.customUpstreamServers = customUpstreamServers
        self.logQueries = logQueries
        self.records = records
    }

    /// dnsmasq is configured with at most this many upstream servers (ticket §5.3.4).
    public static let maximumUpstreamServers = 4

    public var enabledRecords: [LocalDNSRecord] {
        records.filter(\.enabled)
    }
}

/// A local A record (ticket §6.5).
public struct LocalDNSRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var enabled: Bool
    public var hostname: String
    public var ipv4Address: IPv4Address

    /// User's note. Ticket §7.8: never written to the dnsmasq config or the hosts file, so a
    /// comment can never become configuration.
    public var comment: String

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        hostname: String,
        ipv4Address: IPv4Address,
        comment: String = ""
    ) {
        self.id = id
        self.enabled = enabled
        self.hostname = hostname
        self.ipv4Address = ipv4Address
        self.comment = comment
    }

    public static let maximumCommentLength = 200
}
