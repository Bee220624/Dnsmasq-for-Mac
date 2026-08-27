import Foundation
import MacNetModels
import MacNetValidation

/// Decides whether a session may run on an interface, and says why not when it may not.
///
/// ## Why this is a separate, pure type
///
/// This is the safety decision the whole product turns on. Running DHCP on the wrong
/// interface is how Dnsmasq for Mac takes down an office network, and ticket §21.6 lists the cases
/// that must be refused. Keeping the judgment in one pure function means the app and the
/// helper cannot reach different conclusions, and means every case can be tested without a
/// network adapter.
///
/// The app calls this to decide what to show and what to allow selecting. The helper calls it
/// again, on interfaces it enumerated itself, before doing anything (ticket §12.4).
public enum InterfaceSupportPolicy {

    /// Why an interface cannot host a session. Ordered by how emphatically it should be
    /// refused, so that the most important reason is the one reported.
    public enum Rejection: Sendable, Equatable {
        /// The BSD name is not a plain identifier, or names a family macOS manages itself.
        case nameNotPermitted(InterfaceName.Failure)
        /// Wi-Fi. Permanently barred in v0.1 (ticket §7.9).
        case isWiFi
        /// Carries the system's default route (ticket §21.6).
        case isDefaultRoute
        /// Loopback, VPN, bridge, or a virtual interface.
        case kindNotPermitted(NetworkInterfaceKind)

        /// A sentence fit to show the user, explaining the refusal in terms of what they can
        /// do about it rather than which rule fired.
        public var message: String {
            switch self {
            case .nameNotPermitted(.blockedByPolicy):
                "macOS manages this interface. Choose a wired Ethernet adapter instead."
            case .nameNotPermitted:
                "This interface has an unexpected name and cannot be used."
            case .isWiFi:
                "Running DHCP over Wi-Fi would affect every device on the network. "
                    + "Use a wired adapter."
            case .isDefaultRoute:
                "This interface carries this Mac's internet connection. "
                    + "Choose the adapter connected to your device network."
            case .kindNotPermitted(.loopback):
                "The loopback interface is internal to this Mac and reaches no devices."
            case .kindNotPermitted(.bridge):
                "Bridge interfaces are not supported. Choose the underlying adapter instead."
            case .kindNotPermitted(.vpn):
                "VPN interfaces cannot host a DHCP or DNS server."
            case .kindNotPermitted(.virtual):
                "This is a virtual interface, not a physical port."
            case .kindNotPermitted(.unknown):
                // Reached for real hardware macOS reports as something other than Ethernet or
                // Wi-Fi — Bluetooth PAN, FireWire, the Wi-Fi AP interface. Naming the
                // requirement is more useful than naming what we could not classify.
                "Dnsmasq for Mac supports wired Ethernet adapters only."
            case .kindNotPermitted(.ethernet), .kindNotPermitted(.wifi):
                // Unreachable: Ethernet is permitted and Wi-Fi is refused earlier by its own
                // case. Present so that adding a kind is a compile error rather than a
                // silently missing explanation.
                "This interface cannot host a DHCP or DNS server."
            }
        }
    }

    /// Interface kinds that may host a session. Only real wired Ethernet — everything else is
    /// either not a physical network, or one the user did not mean to serve.
    public static let permittedKinds: Set<NetworkInterfaceKind> = [.ethernet]

    /// Evaluates an interface, returning `nil` when it is usable.
    ///
    /// Order matters: the first matching reason is the one reported, and the checks run from
    /// most to least emphatic so a Wi-Fi interface that also carries the default route is
    /// reported as Wi-Fi.
    public static func rejection(
        bsdName: String,
        kind: NetworkInterfaceKind,
        isDefaultRoute: Bool
    ) -> Rejection? {
        if case .failure(let failure) = InterfaceName.validate(bsdName) {
            return .nameNotPermitted(failure)
        }
        if kind == .wifi {
            return .isWiFi
        }
        if isDefaultRoute {
            // Even a wired interface is refused while it carries the default route: serving
            // DHCP there would disrupt the network this Mac is currently depending on.
            return .isDefaultRoute
        }
        if !permittedKinds.contains(kind) {
            return .kindNotPermitted(kind)
        }
        return nil
    }

    /// Sort order for the interface picker (ticket §5.3.2).
    ///
    /// Active Ethernet first, then inactive Ethernet, then other permitted kinds, then
    /// everything refused. Refused interfaces stay visible so a user who plugged into the
    /// wrong port can see it listed and read why it cannot be chosen — hiding it would look
    /// like the adapter was not detected at all.
    public static func sortRank(_ descriptor: NetworkInterfaceDescriptor) -> Int {
        guard descriptor.isSupported else { return 3 }
        guard descriptor.kind == .ethernet else { return 2 }
        return descriptor.isLinkActive ? 0 : 1
    }

    /// Orders interfaces for display: by rank, then by BSD name so the list is stable across
    /// refreshes rather than reshuffling as the system reports them in a different order.
    public static func sorted(
        _ descriptors: [NetworkInterfaceDescriptor]
    ) -> [NetworkInterfaceDescriptor] {
        descriptors.sorted { lhs, rhs in
            let lhsRank = sortRank(lhs)
            let rhsRank = sortRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.bsdName.localizedStandardCompare(rhs.bsdName) == .orderedAscending
        }
    }

    /// Picks a sensible default selection, or `nil` when nothing is safe to preselect
    /// (ticket §12.3).
    ///
    /// The rules that matter are the negative ones: never auto-select Wi-Fi, never auto-select
    /// the default-route interface, and never auto-start. Preferring a previously used
    /// interface is a convenience; refusing to guess when nothing qualifies is the safety
    /// property.
    public static func defaultSelection(
        from descriptors: [NetworkInterfaceDescriptor],
        preferring lastUsedBSDName: String?
    ) -> NetworkInterfaceDescriptor? {
        let usable = descriptors.filter(\.isSupported)

        if let lastUsedBSDName,
           let remembered = usable.first(where: { $0.bsdName == lastUsedBSDName }) {
            return remembered
        }

        // An adapter with a live link is almost certainly the one just plugged in.
        if let active = usable.first(where: { $0.kind == .ethernet && $0.isLinkActive }) {
            return active
        }
        // Otherwise the first permitted Ethernet: the device may simply not be powered yet.
        return usable.first { $0.kind == .ethernet }
    }
}

extension NetworkInterfaceKind {
    public var displayName: String {
        switch self {
        case .ethernet: "Ethernet"
        case .wifi: "Wi-Fi"
        case .loopback: "Loopback"
        case .bridge: "Bridge"
        case .vpn: "VPN"
        case .virtual: "Virtual"
        case .unknown: "Unknown"
        }
    }
}
