import Foundation

extension NetworkProfile {

    /// The profile created on first launch.
    ///
    /// Chosen to be immediately useful for the product's main scenario — a MacBook plugged
    /// straight into a BMC or a switch management port — so a new user can plug in, confirm
    /// the isolation prompt, and press Start.
    ///
    /// `authoritative` is true because a bench network genuinely has no other DHCP server, and
    /// without it a device with a stale lease from somewhere else takes a long time to accept
    /// an address. That is safe **only** because starting DHCP additionally requires the
    /// explicit isolation confirmation, which is never remembered between runs.
    public static func makeDefault(id: UUID = UUID(), now: Date) -> NetworkProfile {
        NetworkProfile(
            id: id,
            name: "Direct Device / BMC",
            interfaceConfiguration: InterfaceConfiguration(
                addTemporaryIPv4Alias: true,
                // 192.168.50.0/24 is private space that is uncommon as a home router default,
                // which reduces the chance of colliding with whatever else is around.
                serverIPv4: IPv4Address(rawValue: 0xC0A8_3201),   // 192.168.50.1
                prefixLength: 24
            ),
            dhcpConfiguration: DHCPConfiguration(
                enabled: true,
                rangeStart: IPv4Address(rawValue: 0xC0A8_320A),   // 192.168.50.10
                rangeEnd: IPv4Address(rawValue: 0xC0A8_32C8),     // 192.168.50.200
                leaseDurationSeconds: 43_200,                     // 12 hours
                authoritative: true,
                // No router by default: Dnsmasq for Mac provides no NAT or IP forwarding, so
                // advertising a gateway would point clients at a route that does not exist.
                advertiseRouter: false,
                routerIPv4: nil,
                advertiseLocalDNSServer: true
            ),
            dnsConfiguration: DNSConfiguration(
                enabled: true,
                // `.test` is reserved by RFC 2606 for exactly this use, so it can never
                // collide with a real registration.
                localDomain: "lab.test",
                upstreamMode: .system,
                customUpstreamServers: [],
                logQueries: false,
                records: []
            ),
            createdAt: now,
            updatedAt: now
        )
    }
}
