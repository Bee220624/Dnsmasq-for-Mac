import Foundation
import MacNetModels
import SystemConfiguration

/// Reads this Mac's current DNS resolvers.
///
/// Read from SystemConfiguration's dynamic store, not by parsing `scutil --dns`. The specification
/// forbids parsing command output for the same reason it does elsewhere: the text is meant for
/// people, it changes between macOS releases, and a parser that is subtly wrong produces a
/// plausible-looking resolver list that would then be written into a dnsmasq configuration.
///
/// Captured once at start rather than followed live. A session's upstream servers should not
/// change underneath it because the Mac joined a different Wi-Fi network mid-session — the
/// snapshot is what makes the running configuration match what the user was shown.
enum SystemResolvers {

    /// The resolvers usable as upstream servers, in order of preference.
    ///
    /// Filtering happens on the helper side too; this is the app's snapshot for display and for
    /// inclusion in the request.
    static func current() -> [IPv4Address] {
        guard let store = SCDynamicStoreCreate(
            nil, "com.bee.dnsmasqformac.resolvers" as CFString, nil, nil
        ) else { return [] }

        let key = SCDynamicStoreKeyCreateNetworkGlobalEntity(
            nil, kSCDynamicStoreDomainState, kSCEntNetDNS
        )
        guard let dns = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let addresses = dns[kSCPropNetDNSServerAddresses as String] as? [String]
        else { return [] }

        // IPv6 resolvers are dropped rather than mangled: v0.1 forwards over IPv4 only, and an
        // address dnsmasq cannot use is worse than one fewer server.
        return addresses.compactMap(IPv4Address.init)
    }
}
