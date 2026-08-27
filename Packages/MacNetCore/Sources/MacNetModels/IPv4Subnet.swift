import Foundation

/// An IPv4 network derived from an address and a prefix length.
///
/// Every subnet question the product asks — is this address in range, is it the network or
/// broadcast address, how many hosts fit — is answered here rather than being recomputed with
/// ad-hoc shifts at each call site.
public struct IPv4Subnet: Sendable, Hashable {

    /// Prefix lengths v0.1 permits.
    ///
    /// `/31` and `/32` are excluded because neither leaves room for a server address plus a
    /// DHCP pool, so accepting them would only produce a confusing failure later.
    public static let allowedPrefixLengths: ClosedRange<Int> = 8...30

    /// Below this, the subnet is enormous and almost certainly a typo. Allowed, but the UI
    /// warns.
    public static let warnBelowPrefixLength = 16

    public let prefixLength: Int
    /// Network address — the all-zero-host address.
    public let networkAddress: IPv4Address

    /// Fails if `prefixLength` is outside the allowed range, so an `IPv4Subnet` always
    /// represents a usable network.
    public init?(containing address: IPv4Address, prefixLength: Int) {
        guard Self.allowedPrefixLengths.contains(prefixLength) else { return nil }
        self.prefixLength = prefixLength
        networkAddress = IPv4Address(
            rawValue: address.rawValue & Self.netmaskValue(for: prefixLength)
        )
    }

    private static func netmaskValue(for prefixLength: Int) -> UInt32 {
        // A prefix of 0 would make this shift undefined; `init` has already excluded it.
        UInt32.max << (32 - prefixLength)
    }

    /// Dotted-quad netmask, e.g. `/24` → `255.255.255.0`.
    public var netmask: IPv4Address {
        IPv4Address(rawValue: Self.netmaskValue(for: prefixLength))
    }

    /// The all-ones-host address.
    public var broadcastAddress: IPv4Address {
        IPv4Address(rawValue: networkAddress.rawValue | ~Self.netmaskValue(for: prefixLength))
    }

    /// Lowest address that may be assigned to a host.
    public var firstHostAddress: IPv4Address {
        IPv4Address(rawValue: networkAddress.rawValue + 1)
    }

    /// Highest address that may be assigned to a host.
    public var lastHostAddress: IPv4Address {
        IPv4Address(rawValue: broadcastAddress.rawValue - 1)
    }

    /// How many addresses are assignable to hosts, excluding network and broadcast.
    ///
    /// `UInt32` because a `/8` holds more than sixteen million, which overflows `Int32`.
    public var usableHostCount: UInt32 {
        (1 << UInt32(32 - prefixLength)) - 2
    }

    public func contains(_ address: IPv4Address) -> Bool {
        address.rawValue & Self.netmaskValue(for: prefixLength) == networkAddress.rawValue
    }

    /// True when the address is inside this subnet *and* usable by a host — i.e. neither the
    /// network nor the broadcast address.
    public func isUsableHostAddress(_ address: IPv4Address) -> Bool {
        contains(address)
            && address != networkAddress
            && address != broadcastAddress
            && address.isAssignableHostAddress
    }

    /// True when the prefix is wide enough to be worth warning about.
    public var isUnusuallyWide: Bool { prefixLength < Self.warnBelowPrefixLength }
}
