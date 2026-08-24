import Foundation

/// Validation for BSD interface names (ticket §7.9).
///
/// The helper receives an interface name from the app and passes it to `/sbin/ifconfig` as an
/// argument and into a dnsmasq configuration file. Even though it is never interpreted by a
/// shell, a name that is not a plain identifier has no legitimate use and is refused.
public enum InterfaceName {

    public enum Failure: String, Sendable, Equatable, Error {
        case empty
        case malformed
        case blockedByPolicy
    }

    /// Prefixes that may never host a session (ticket §7.9).
    ///
    /// Every one of these is either not a real network, or is one macOS manages itself:
    /// loopback, Apple Wireless Direct Link, low-latency WLAN, VPN tunnels, bridges, and the
    /// various tunnel and peer-to-peer pseudo-interfaces. Serving DHCP on any of them ranges
    /// from useless to actively disruptive.
    public static let blockedPrefixes = [
        "lo", "awdl", "llw", "utun", "bridge", "gif", "stf", "p2p", "ipsec", "ppp", "anpi",
    ]

    /// Validates the shape of a name and applies the blocklist.
    ///
    /// Shape only — whether the interface exists, what type it is, and whether it carries the
    /// default route are separate questions the helper answers by re-enumerating the system
    /// (ticket §12.4). A name passing here is not yet permission to use it.
    public static func validate(_ input: String) -> Result<String, Failure> {
        guard !input.isEmpty else { return .failure(.empty) }

        // ^[a-z][a-z0-9]{0,15}$ from ticket §7.9, checked directly rather than by regular
        // expression so the rule is readable and cannot be defeated by a pattern subtlety.
        guard input.count <= 16 else { return .failure(.malformed) }
        guard let first = input.first, first.isASCII, first.isLowercase, first.isLetter else {
            return .failure(.malformed)
        }
        let isAllowed: (Character) -> Bool = { character in
            character.isASCII && (character.isLowercase && character.isLetter
                || character.isNumber)
        }
        guard input.allSatisfy(isAllowed) else { return .failure(.malformed) }

        // A blocked family is its prefix followed by a unit number and nothing else, so
        // `utun0`, `utun12`, and `p2p0` are all caught without enumerating unit numbers.
        //
        // Taking the leading *letters* instead would miss `p2p0`, whose family name contains
        // a digit. Requiring the remainder to be all digits is also what keeps this from
        // over-blocking: a hypothetical `loopback0` starts with "lo" but does not match,
        // because "opback0" is not a unit number.
        let isBlocked = blockedPrefixes.contains { family in
            guard input.hasPrefix(family) else { return false }
            let unit = input.dropFirst(family.count)
            return unit.allSatisfy(\.isNumber)
        }
        guard !isBlocked else { return .failure(.blockedByPolicy) }

        return .success(input)
    }
}
