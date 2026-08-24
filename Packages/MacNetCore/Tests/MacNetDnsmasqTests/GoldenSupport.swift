import Foundation
import Testing
import MacNetModels
import MacNetDnsmasq

/// Shared scaffolding for the configuration generator's golden tests.
enum Golden {

    /// Fixed session directory so golden files contain a stable path. A real session uses a
    /// UUID; substituting a constant here is what keeps the output comparable run to run.
    static let paths = RuntimePaths(
        sessionDirectory: "/var/db/com.bee.macnetlab/sessions/SESSION_ID"
    )

    static func address(_ text: String) -> IPv4Address {
        guard let parsed = IPv4Address(text) else {
            Issue.record("test supplied an invalid address literal: \(text)")
            return IPv4Address(rawValue: 0)
        }
        return parsed
    }

    /// Builds a profile from the shipping default, overriding only what a scenario is about.
    static func profile(
        serverIPv4: String = "192.168.50.1",
        prefixLength: Int = 24,
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
        upstreamMode: DNSUpstreamMode = .custom,
        customUpstreams: [String] = ["1.1.1.1", "8.8.8.8"],
        logQueries: Bool = false,
        records: [LocalDNSRecord] = []
    ) -> NetworkProfile {
        NetworkProfile(
            name: "Golden",
            interfaceConfiguration: InterfaceConfiguration(
                addTemporaryIPv4Alias: true,
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
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func record(
        _ hostname: String,
        _ ipv4: String,
        enabled: Bool = true,
        comment: String = ""
    ) -> LocalDNSRecord {
        LocalDNSRecord(
            enabled: enabled, hostname: hostname, ipv4Address: address(ipv4), comment: comment
        )
    }

    static func generate(
        _ profile: NetworkProfile,
        interface: String = "en7",
        systemDNS: [String] = []
    ) throws -> GeneratedDnsmasqConfiguration {
        let request = try ValidatedSessionRequest(
            profile: profile,
            interfaceBSDName: interface,
            systemDNSServers: systemDNS.map(address)
        )
        return DnsmasqConfigurationGenerator().generate(request: request, paths: paths)
    }

    /// Compares against a golden file, reporting the first differing line rather than dumping
    /// two blocks of text and leaving the reader to spot the difference.
    static func expectMatchesGolden(
        _ actual: String,
        _ goldenName: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let url = try #require(
            Bundle.module.url(forResource: "Golden/\(goldenName)", withExtension: nil),
            "missing golden file: \(goldenName)",
            sourceLocation: sourceLocation
        )
        let expected = try String(contentsOf: url, encoding: .utf8)

        guard actual != expected else { return }

        let actualLines = actual.components(separatedBy: "\n")
        let expectedLines = expected.components(separatedBy: "\n")

        for index in 0..<max(actualLines.count, expectedLines.count) {
            let lhs = index < actualLines.count ? actualLines[index] : "<missing>"
            let rhs = index < expectedLines.count ? expectedLines[index] : "<missing>"
            if lhs != rhs {
                Issue.record(
                    """
                    \(goldenName) differs at line \(index + 1)
                      expected: \(rhs.debugDescription)
                        actual: \(lhs.debugDescription)
                    """,
                    sourceLocation: sourceLocation
                )
                return
            }
        }
        Issue.record("\(goldenName) differs only in trailing content", sourceLocation: sourceLocation)
    }
}
