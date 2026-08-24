import Foundation

/// Broad classification of a network interface (ticket §6.6).
///
/// Derived from SystemConfiguration's interface type, never from the BSD name. Ticket §7.9 is
/// explicit that `en0` must not be assumed to be Wi-Fi — on a Mac mini it is Ethernet, and
/// guessing wrong here means either blocking a valid interface or, far worse, running DHCP on
/// Wi-Fi.
public enum NetworkInterfaceKind: String, Codable, Sendable, CaseIterable {
    case ethernet
    case wifi
    case loopback
    case bridge
    case vpn
    case virtual
    case unknown
}

/// One IPv4 address currently configured on an interface.
public struct InterfaceIPv4Address: Codable, Sendable, Equatable, Hashable {
    public let address: IPv4Address
    public let netmask: IPv4Address

    public init(address: IPv4Address, netmask: IPv4Address) {
        self.address = address
        self.netmask = netmask
    }

    /// Prefix length implied by the netmask, or `nil` if the mask is not contiguous.
    ///
    /// A non-contiguous mask is legal to configure and meaningless in practice; reporting
    /// `nil` keeps that oddity visible instead of inventing a number for it.
    public var prefixLength: Int? {
        let value = netmask.rawValue
        let leadingOnes = (~value).leadingZeroBitCount
        // Every bit below the leading ones must be zero for the mask to be contiguous.
        let expected = leadingOnes == 0 ? 0 : UInt32.max << (32 - leadingOnes)
        return value == expected ? leadingOnes : nil
    }
}

/// Everything the app and helper know about one interface (ticket §6.6).
///
/// Captured as a snapshot and carried in the session request, but the helper never trusts it:
/// ticket §12.4 requires re-enumeration at preflight and again at start, because an interface
/// can be unplugged between the user choosing it and the service starting.
public struct NetworkInterfaceDescriptor: Codable, Sendable, Equatable, Identifiable {
    public var id: String { bsdName }

    /// e.g. `en7`.
    public let bsdName: String
    /// Localized name from SystemConfiguration, e.g. "USB 10/100/1000 LAN".
    public let displayName: String
    public let hardwarePortName: String?
    public let kind: NetworkInterfaceKind
    public let macAddress: String?
    public let ipv4Addresses: [InterfaceIPv4Address]

    /// `IFF_UP`: administratively enabled.
    public let isUp: Bool
    /// `IFF_RUNNING`: resources allocated.
    public let isRunning: Bool
    /// Carrier detected — something is plugged in and powered.
    public let isLinkActive: Bool
    /// Carries the system's default route. Serving DHCP here would disrupt the network this
    /// Mac depends on, so it is refused outright (ticket §21.6).
    public let isDefaultRoute: Bool

    /// Whether a session may run on this interface at all.
    public let isSupported: Bool
    /// Why not, in words fit to show the user. Non-nil exactly when `isSupported` is false.
    public let unsupportedReason: String?

    public init(
        bsdName: String,
        displayName: String,
        hardwarePortName: String?,
        kind: NetworkInterfaceKind,
        macAddress: String?,
        ipv4Addresses: [InterfaceIPv4Address],
        isUp: Bool,
        isRunning: Bool,
        isLinkActive: Bool,
        isDefaultRoute: Bool,
        isSupported: Bool,
        unsupportedReason: String?
    ) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.hardwarePortName = hardwarePortName
        self.kind = kind
        self.macAddress = macAddress
        self.ipv4Addresses = ipv4Addresses
        self.isUp = isUp
        self.isRunning = isRunning
        self.isLinkActive = isLinkActive
        self.isDefaultRoute = isDefaultRoute
        self.isSupported = isSupported
        self.unsupportedReason = unsupportedReason
    }

    public func hasAddress(_ address: IPv4Address) -> Bool {
        ipv4Addresses.contains { $0.address == address }
    }

    /// The configured entry for `address`, if the interface already has it. Used to tell
    /// "already present, leave it alone" apart from "present with a different prefix", which
    /// is a conflict rather than a no-op (ticket §13.1).
    public func existingEntry(for address: IPv4Address) -> InterfaceIPv4Address? {
        ipv4Addresses.first { $0.address == address }
    }
}
