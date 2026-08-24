import Foundation

/// A validated IPv4 address.
///
/// The only way to obtain one from text is `init?(_:)`, which is strict. Once you hold an
/// `IPv4Address` it is guaranteed to be a well-formed, unambiguous address — so code further
/// down, especially the dnsmasq configuration generator, never has to re-check or re-parse.
public struct IPv4Address: Sendable, Hashable, Comparable, CustomStringConvertible {

    /// The address in host byte order, so ordering and arithmetic behave as written.
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Parses dotted-quad text, rejecting anything ambiguous.
    ///
    /// Parsing is delegated to `inet_pton`, which correctly rejects short forms, extra
    /// octets, out-of-range octets, negatives, embedded whitespace, CIDR suffixes, hex
    /// literals, hostnames, IPv6, and trailing dots. Ticket §7.1 requires exactly that
    /// instead of splitting on "." and hoping.
    ///
    /// One case is rejected *beyond* what `inet_pton` does: **leading zeros**. macOS's
    /// `inet_pton` accepts `010.1.1.1` and reads it as decimal 10, while a great many other
    /// parsers — including some C libraries and shell tools — read a leading zero as octal
    /// and get 8. These addresses are written into a dnsmasq configuration file and compared
    /// against interface addresses, so an input that two parsers disagree about is a real
    /// hazard, not a theoretical one. Refusing it removes the ambiguity entirely.
    public init?(_ text: String) {
        guard Self.hasNoLeadingZeros(text) else { return nil }

        var address = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            return nil
        }
        rawValue = UInt32(bigEndian: address.s_addr)
    }

    /// True unless some octet is written with a redundant leading zero.
    ///
    /// Runs before `inet_pton` and assumes nothing about the shape of the input: anything
    /// malformed simply falls through to `inet_pton`, which rejects it.
    private static func hasNoLeadingZeros(_ text: String) -> Bool {
        for octet in text.split(separator: ".", omittingEmptySubsequences: false) {
            if octet.count > 1, octet.first == "0" { return false }
        }
        return true
    }

    public var description: String {
        "\((rawValue >> 24) & 0xFF).\((rawValue >> 16) & 0xFF)"
            + ".\((rawValue >> 8) & 0xFF).\(rawValue & 0xFF)"
    }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Codable

extension IPv4Address: Codable {
    /// Encoded as dotted-quad text so that profiles and journals stay human-readable and
    /// hand-editable in an emergency. Decoding applies the same strict validation as parsing
    /// user input — a hand-edited file is untrusted input like any other.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = IPv4Address(text) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "'\(text)' is not a valid IPv4 address"
                )
            )
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Well-known ranges

extension IPv4Address {
    public static let any = IPv4Address(rawValue: 0)
    public static let broadcast = IPv4Address(rawValue: 0xFFFF_FFFF)

    /// RFC 1918 private space — the only ranges v0.1 allows for a server address
    /// (ticket §7.2). A lab network should never be numbered out of public space.
    public var isPrivateUse: Bool {
        let octet1 = (rawValue >> 24) & 0xFF
        let octet2 = (rawValue >> 16) & 0xFF
        switch octet1 {
        case 10: return true                          // 10.0.0.0/8
        case 172: return (16...31).contains(octet2)   // 172.16.0.0/12
        case 192: return octet2 == 168                // 192.168.0.0/16
        default: return false
        }
    }

    /// 127.0.0.0/8
    public var isLoopback: Bool { (rawValue >> 24) & 0xFF == 127 }

    /// 169.254.0.0/16. Excluded because macOS assigns these itself when DHCP fails, so
    /// serving from one would collide with the OS.
    public var isLinkLocal: Bool { (rawValue >> 16) == 0xA9FE }

    /// 224.0.0.0/4
    public var isMulticast: Bool { (rawValue >> 28) == 0xE }

    /// 0.0.0.0/8
    public var isUnspecified: Bool { (rawValue >> 24) & 0xFF == 0 }

    public var isLimitedBroadcast: Bool { rawValue == 0xFFFF_FFFF }

    /// Whether this address is usable as a host address at all, independent of any subnet.
    public var isAssignableHostAddress: Bool {
        !isUnspecified && !isLoopback && !isLinkLocal && !isMulticast && !isLimitedBroadcast
            && (rawValue >> 28) != 0xF   // 240.0.0.0/4 reserved
    }
}

// MARK: - Arithmetic

extension IPv4Address {
    /// Returns the address `offset` higher, or `nil` on overflow past 255.255.255.255.
    ///
    /// Optional rather than wrapping: silently wrapping to 0.0.0.0 at the top of the space
    /// would turn an arithmetic mistake into a wrong-but-plausible address.
    public func adding(_ offset: UInt32) -> IPv4Address? {
        let (sum, overflow) = rawValue.addingReportingOverflow(offset)
        return overflow ? nil : IPv4Address(rawValue: sum)
    }

    /// Number of addresses from this one up to and including `other`, or `nil` if `other` is
    /// lower.
    public func addressCount(through other: IPv4Address) -> UInt32? {
        guard other.rawValue >= rawValue else { return nil }
        return other.rawValue - rawValue + 1
    }
}
