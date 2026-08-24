import Foundation
import MacNetModels

/// Builds profiles for tests.
///
/// Starts from the shipping default (ticket §8) and lets each test change only the field it
/// is about, so a test's intent is visible in its diff from a known-good configuration rather
/// than buried in twenty lines of setup.
enum ProfileFixture {

    static func address(_ text: String) -> IPv4Address {
        // Tests supply literals; a nil here is a broken test, not a runtime condition.
        guard let parsed = IPv4Address(text) else {
            fatalError("ProfileFixture was given an invalid address literal: \(text)")
        }
        return parsed
    }

    static func make(
        name: String = "Direct Device / BMC",
        serverIPv4: String = "192.168.50.1",
        prefixLength: Int = 24,
        addAlias: Bool = true,
        dhcpEnabled: Bool = true,
        rangeStart: String = "192.168.50.10",
        rangeEnd: String = "192.168.50.200",
        leaseSeconds: Int = 43_200,
        authoritative: Bool = true,
        advertiseRouter: Bool = false,
        routerIPv4: String? = nil,
        advertiseLocalDNS: Bool = true,
        dnsEnabled: Bool = true,
        localDomain: String = "lab.test",
        upstreamMode: DNSUpstreamMode = .system,
        customUpstreams: [String] = [],
        logQueries: Bool = false,
        records: [LocalDNSRecord] = []
    ) -> NetworkProfile {
        NetworkProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            name: name,
            interfaceConfiguration: InterfaceConfiguration(
                addTemporaryIPv4Alias: addAlias,
                serverIPv4: address(serverIPv4),
                prefixLength: prefixLength
            ),
            dhcpConfiguration: DHCPConfiguration(
                enabled: dhcpEnabled,
                rangeStart: address(rangeStart),
                rangeEnd: address(rangeEnd),
                leaseDurationSeconds: leaseSeconds,
                authoritative: authoritative,
                advertiseRouter: advertiseRouter,
                routerIPv4: routerIPv4.map(address),
                advertiseLocalDNSServer: advertiseLocalDNS
            ),
            dnsConfiguration: DNSConfiguration(
                enabled: dnsEnabled,
                localDomain: localDomain,
                upstreamMode: upstreamMode,
                customUpstreamServers: customUpstreams.map(address),
                logQueries: logQueries,
                records: records
            ),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func record(
        _ hostname: String,
        _ ipv4: String,
        enabled: Bool = true,
        comment: String = ""
    ) -> LocalDNSRecord {
        LocalDNSRecord(
            enabled: enabled,
            hostname: hostname,
            ipv4Address: address(ipv4),
            comment: comment
        )
    }
}
