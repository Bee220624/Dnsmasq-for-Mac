import Darwin
import Foundation
import MacNetModels
import SystemConfiguration

/// Reads the machine's network interfaces.
///
/// A protocol so that everything above it can be tested against fixtures. Ticket §24.2
/// requires the helper's system calls to be injectable; this is the interface half of that.
public protocol InterfaceEnumerating: Sendable {
    func enumerateInterfaces() -> [NetworkInterfaceDescriptor]
}

/// The real implementation, reading from the running system.
///
/// ## Why not parse command output
///
/// Ticket §12.1 forbids building this list by parsing `ifconfig`, `networksetup`, or `scutil`.
/// Their output is meant for people: it is localized, it changes between macOS releases, and a
/// parser that is subtly wrong produces a plausible-looking interface list — which is exactly
/// how you end up serving DHCP on the wrong port. The APIs used here return structured data
/// that means what it says.
///
/// Three sources are combined, because no single one has everything:
///
/// * `getifaddrs` — flags, IPv4 addresses and netmasks, hardware addresses.
/// * `SCNetworkInterfaceCopyAll` — the localized display name and the *interface type*, which
///   is the only trustworthy way to tell Wi-Fi from Ethernet.
/// * `SCDynamicStore` — which interface currently carries the default route.
///
/// Deciding Wi-Fi by name would be a serious bug: `en0` is Wi-Fi on a laptop and Ethernet on a
/// Mac mini, and guessing wrong means either blocking a valid adapter or serving DHCP over
/// Wi-Fi (ticket §7.9).
public struct SystemInterfaceEnumerator: InterfaceEnumerating {

    public init() {}

    public func enumerateInterfaces() -> [NetworkInterfaceDescriptor] {
        let metadata = Self.readSystemConfigurationMetadata()
        let primaryInterface = Self.readPrimaryIPv4Interface()
        let linkState = Self.readInterfaceFlags()

        let descriptors = linkState.map { bsdName, state -> NetworkInterfaceDescriptor in
            let info = metadata[bsdName]
            let kind = info?.kind ?? Self.inferKind(bsdName: bsdName, isLoopback: state.isLoopback)
            let isDefaultRoute = bsdName == primaryInterface

            let rejection = InterfaceSupportPolicy.rejection(
                bsdName: bsdName,
                kind: kind,
                isDefaultRoute: isDefaultRoute
            )

            return NetworkInterfaceDescriptor(
                bsdName: bsdName,
                displayName: info?.displayName ?? bsdName,
                hardwarePortName: info?.displayName,
                kind: kind,
                macAddress: state.macAddress,
                ipv4Addresses: state.ipv4Addresses,
                isUp: state.isUp,
                isRunning: state.isRunning,
                isLinkActive: state.isLinkActive,
                isDefaultRoute: isDefaultRoute,
                isSupported: rejection == nil,
                unsupportedReason: rejection?.message
            )
        }

        return InterfaceSupportPolicy.sorted(descriptors)
    }

    // MARK: - getifaddrs

    private struct InterfaceState {
        var isUp = false
        var isRunning = false
        var isLoopback = false
        var isLinkActive = false
        var macAddress: String?
        var ipv4Addresses: [InterfaceIPv4Address] = []
    }

    /// Walks `getifaddrs`, collapsing its per-address entries into one record per interface.
    ///
    /// An interface appears once per address family and once per address, so the same name is
    /// seen several times and the fields are merged as they arrive.
    private static func readInterfaceFlags() -> [String: InterfaceState] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var states: [String: InterfaceState] = [:]

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            var state = states[name] ?? InterfaceState()

            let flags = Int32(entry.pointee.ifa_flags)
            state.isUp = flags & IFF_UP != 0
            state.isRunning = flags & IFF_RUNNING != 0
            state.isLoopback = flags & IFF_LOOPBACK != 0

            if let address = entry.pointee.ifa_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_LINK:
                    if let mac = Self.hardwareAddress(from: address) {
                        state.macAddress = mac
                    }

                case AF_INET:
                    if let ipv4 = Self.ipv4Entry(
                        address: address, netmask: entry.pointee.ifa_netmask
                    ) {
                        state.ipv4Addresses.append(ipv4)
                    }

                default:
                    break
                }
            }

            states[name] = state
        }

        // Carrier detection needs a separate ioctl; IFF_RUNNING is close but not the same
        // thing, and the difference matters when a cable is unplugged from a live interface.
        //
        // The carrier value is computed before the mutation so that reading and writing
        // `states` are not overlapping accesses to the same dictionary.
        for name in Array(states.keys) {
            let fallback = states[name]?.isRunning ?? false
            let carrier = Self.isLinkActive(bsdName: name) ?? fallback
            states[name]?.isLinkActive = carrier
        }

        return states
    }

    /// Formats a link-level address as colon-separated lowercase hex.
    private static func hardwareAddress(from address: UnsafeMutablePointer<sockaddr>) -> String? {
        address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
            let length = Int(link.pointee.sdl_alen)
            // Only Ethernet-style 6-byte addresses; anything else is not a MAC worth showing.
            guard length == 6 else { return nil }

            // The hardware address follows the interface name inside sdl_data, so the name
            // length is the offset.
            let base = UnsafeRawPointer(link).advanced(
                by: MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) ?? 8
            )
            let bytes = base.advanced(by: Int(link.pointee.sdl_nlen))
                .assumingMemoryBound(to: UInt8.self)

            return (0..<length)
                .map { String(format: "%02x", bytes[$0]) }
                .joined(separator: ":")
        }
    }

    private static func ipv4Entry(
        address: UnsafeMutablePointer<sockaddr>,
        netmask: UnsafeMutablePointer<sockaddr>?
    ) -> InterfaceIPv4Address? {
        func value(_ pointer: UnsafeMutablePointer<sockaddr>?) -> IPv4Address? {
            guard let pointer, Int32(pointer.pointee.sa_family) == AF_INET else { return nil }
            let raw = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            return IPv4Address(rawValue: raw)
        }

        guard let parsed = value(address) else { return nil }
        // A missing netmask is reported as /32 rather than dropped: the address is real and
        // hiding it would make the interface look unconfigured.
        let mask = value(netmask) ?? IPv4Address(rawValue: 0xFFFF_FFFF)
        return InterfaceIPv4Address(address: parsed, netmask: mask)
    }

    /// `SIOCGIFMEDIA`, computed rather than imported.
    ///
    /// The constant is defined in `<sys/sockio.h>` as `_IOWR('i', 56, struct ifmediareq)`.
    /// `_IOWR` is a function-like macro, so Swift does not import it and the value has to be
    /// assembled from the same pieces: direction bits, encoded parameter size, group letter,
    /// and command number.
    private static let siocgifmedia: UInt = {
        let directionInOut: UInt32 = 0xC000_0000                      // IOC_IN | IOC_OUT
        let parameterLength = UInt32(MemoryLayout<ifmediareq>.size) & 0x1FFF  // IOCPARM_MASK
        let group = UInt32(UInt8(ascii: "i")) << 8
        return UInt(directionInOut | (parameterLength << 16) | group | 56)
    }()

    /// Reads carrier state — is something actually plugged in and powered.
    ///
    /// Returns `nil` when the interface cannot answer, which is normal for loopback and most
    /// virtual interfaces. Callers fall back to `IFF_RUNNING`, which is close but not the same
    /// thing: the difference shows when a cable is unplugged from an otherwise live interface.
    private static func isLinkActive(bsdName: String) -> Bool? {
        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketDescriptor >= 0 else { return nil }
        defer { close(socketDescriptor) }

        var request = ifmediareq()
        let didCopyName = withUnsafeMutableBytes(of: &request.ifm_name) { buffer -> Bool in
            var name = Array(bsdName.utf8)
            // ifm_name is IFNAMSIZ (16) bytes and must be NUL-terminated. A name that does not
            // fit cannot be a real interface, so this reports failure rather than truncating
            // into a query about some other interface.
            guard name.count < buffer.count else { return false }
            name.append(0)
            buffer.copyBytes(from: name)
            return true
        }
        guard didCopyName else { return nil }

        guard ioctl(socketDescriptor, siocgifmedia, &request) == 0 else { return nil }
        guard request.ifm_status & IFM_AVALID != 0 else { return nil }
        return request.ifm_status & IFM_ACTIVE != 0
    }

    // MARK: - SystemConfiguration

    private struct InterfaceMetadata {
        let displayName: String
        let kind: NetworkInterfaceKind
    }

    private static func readSystemConfigurationMetadata() -> [String: InterfaceMetadata] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return [:]
        }

        var metadata: [String: InterfaceMetadata] = [:]
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
                continue
            }
            let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            let type = SCNetworkInterfaceGetInterfaceType(interface) as String?

            metadata[bsdName] = InterfaceMetadata(
                displayName: displayName ?? bsdName,
                kind: kind(forInterfaceType: type)
            )
        }
        return metadata
    }

    /// Maps a SystemConfiguration interface type to our classification.
    ///
    /// This is the authoritative answer to "is this Wi-Fi", and the reason the product can
    /// refuse Wi-Fi reliably rather than by guessing from the name.
    private static func kind(forInterfaceType type: String?) -> NetworkInterfaceKind {
        guard let type else { return .unknown }

        // Only the constants SystemConfiguration actually declares. There is no loopback or
        // bridge type: those interfaces do not appear here at all, and are classified by the
        // name-based fallback below.
        switch type as CFString {
        case kSCNetworkInterfaceTypeEthernet:
            return .ethernet
        case kSCNetworkInterfaceTypeIEEE80211:
            return .wifi
        case kSCNetworkInterfaceTypeIPSec, kSCNetworkInterfaceTypePPP,
             kSCNetworkInterfaceTypeL2TP:
            return .vpn
        case kSCNetworkInterfaceTypeBond, kSCNetworkInterfaceTypeVLAN,
             kSCNetworkInterfaceType6to4:
            return .virtual
        case kSCNetworkInterfaceTypeBluetooth, kSCNetworkInterfaceTypeWWAN,
             kSCNetworkInterfaceTypeModem, kSCNetworkInterfaceTypeSerial,
             kSCNetworkInterfaceTypeFireWire:
            // Real interfaces, but not wired Ethernet ports. Reported honestly as unknown so
            // they are listed and refused with a reason, rather than hidden.
            return .unknown
        default:
            return .unknown
        }
    }

    /// The interface currently carrying the default IPv4 route (ticket §12.1).
    ///
    /// Read from the dynamic store rather than by parsing `netstat -rn`, for the same reason
    /// the rest of this type avoids command output.
    private static func readPrimaryIPv4Interface() -> String? {
        guard let store = SCDynamicStoreCreate(
            nil, "com.bee.dnsmasqformac.interfaces" as CFString, nil, nil
        ) else { return nil }

        let key = SCDynamicStoreKeyCreateNetworkGlobalEntity(
            nil, kSCDynamicStoreDomainState, kSCEntNetIPv4
        )
        guard let global = SCDynamicStoreCopyValue(store, key) as? [String: Any] else {
            return nil
        }
        return global[kSCDynamicStorePropNetPrimaryInterface as String] as? String
    }

    /// Fallback classification when SystemConfiguration has nothing to say about an interface.
    ///
    /// Only reached for pseudo-interfaces that never appear in the network preferences, such
    /// as `utun` tunnels and `awdl`. Those are all barred by name anyway, so an imperfect
    /// guess here cannot make an unsafe interface look safe.
    private static func inferKind(bsdName: String, isLoopback: Bool) -> NetworkInterfaceKind {
        if isLoopback { return .loopback }
        let letters = String(bsdName.prefix(while: \.isLetter))
        switch letters {
        case "utun", "ipsec", "ppp": return .vpn
        case "bridge": return .bridge
        case "awdl", "llw", "p", "gif", "stf", "anpi": return .virtual
        default: return .unknown
        }
    }
}
