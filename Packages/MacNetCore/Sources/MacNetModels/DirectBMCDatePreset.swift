import Foundation

/// A single-address pool for one BMC on a direct cable. Applying it changes the local
/// profile only; an existing BMC lease still requires a request from the DHCP client.
public enum DirectBMCDatePreset {
    public static func applying(
        to profile: NetworkProfile,
        on date: Date = Date(),
        calendar: Calendar = .current
    ) -> NetworkProfile? {
        let interface = profile.interfaceConfiguration
        guard profile.dhcpConfiguration.enabled,
              interface.prefixLength == 24,
              interface.serverIPv4.isPrivateUse
        else { return nil }

        let day = calendar.component(.day, from: date)
        guard (1...31).contains(day) else { return nil }
        let address = IPv4Address(rawValue: (interface.serverIPv4.rawValue & 0xFFFF_FF00)
                                  | UInt32(100 + day))
        guard address != interface.serverIPv4,
              !profile.dhcpConfiguration.advertiseRouter
                || address != profile.dhcpConfiguration.routerIPv4
        else { return nil }

        var updated = profile
        updated.dhcpConfiguration.rangeStart = address
        updated.dhcpConfiguration.rangeEnd = address
        return updated
    }
}
