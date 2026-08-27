import Foundation
import MacNetModels
import MacNetValidation

/// A session request that has passed every validation rule.
///
/// ## Why this type exists
///
/// The configuration generator writes strings straight into a file that a root process then
/// executes against. If it had to decide what was safe, every future edit to it would be a
/// chance to introduce an injection. Instead, validation happens once, here, and the
/// generator accepts only a value that cannot be constructed without passing it.
///
/// `init` is the only way in, and it is failable. Holding a `ValidatedSessionRequest` is
/// proof that the interface name is a plain identifier, the addresses are unambiguous, the
/// domain and every hostname are well-formed, and the DHCP pool is coherent.
public struct ValidatedSessionRequest: Sendable, Equatable {

    public let interfaceBSDName: String
    public let serverIPv4: IPv4Address
    public let subnet: IPv4Subnet

    public let dhcp: DHCPConfiguration
    public let dns: DNSConfiguration

    /// The local domain, normalized. Use this rather than `dns.localDomain`, which is raw
    /// user input.
    public let normalizedLocalDomain: String

    /// Upstream servers to write, already resolved for the selected mode: the system snapshot
    /// for `.system`, the user's list for `.custom`, and empty for `.localOnly`.
    public let upstreamServers: [IPv4Address]

    /// Enabled records, resolved to their final names and de-duplicated.
    public let hostEntries: [HostEntry]

    /// One line's worth of a generated hosts file.
    public struct HostEntry: Sendable, Equatable {
        public let address: IPv4Address
        /// FQDN first, then the short name when the user gave a relative one.
        public let names: [String]
    }

    public enum Failure: Sendable, Equatable, Error {
        case interfaceName(InterfaceName.Failure)
        case configuration([ValidationIssue])
        /// `.system` mode was requested but the caller supplied no usable resolvers.
        case noUsableSystemDNSServers
    }

    /// Validates a profile and interface into a request the generator will accept.
    ///
    /// - Parameter systemDNSServers: resolvers captured from SystemConfiguration at start.
    ///   Only consulted in `.system` mode.
    public init(
        profile: NetworkProfile,
        interfaceBSDName: String,
        systemDNSServers: [IPv4Address]
    ) throws(Failure) {
        switch InterfaceName.validate(interfaceBSDName) {
        case .success(let name): self.interfaceBSDName = name
        case .failure(let failure): throw Failure.interfaceName(failure)
        }

        let issues = ConfigurationValidator.validate(profile)
        guard !ConfigurationValidator.hasBlockingIssues(issues) else {
            throw Failure.configuration(issues.filter { $0.severity == .error })
        }

        let interfaceConfiguration = profile.interfaceConfiguration
        serverIPv4 = interfaceConfiguration.serverIPv4

        // Validation already accepted the prefix length, so this cannot fail — but the type
        // system does not know that, and forcing it would be the one force-unwrap in the
        // codebase. Re-reporting as a validation failure keeps the guarantee honest.
        guard let subnet = interfaceConfiguration.subnet else {
            throw Failure.configuration(issues)
        }
        self.subnet = subnet

        dhcp = profile.dhcpConfiguration
        dns = profile.dnsConfiguration

        let domain = DomainName.normalize(profile.dnsConfiguration.localDomain)
        normalizedLocalDomain = domain

        upstreamServers = try Self.resolveUpstreams(
            dns: profile.dnsConfiguration,
            systemDNSServers: systemDNSServers,
            serverIPv4: interfaceConfiguration.serverIPv4
        )

        hostEntries = try Self.resolveHostEntries(
            records: profile.dnsConfiguration.records,
            localDomain: domain
        )
    }

    // MARK: - Upstream resolution

    private static func resolveUpstreams(
        dns: DNSConfiguration,
        systemDNSServers: [IPv4Address],
        serverIPv4: IPv4Address
    ) throws(Failure) -> [IPv4Address] {
        guard dns.enabled else { return [] }

        switch dns.upstreamMode {
        case .localOnly:
            // No upstream at all. External lookups failing is the point of this mode.
            return []

        case .custom:
            return Array(dns.customUpstreamServers.prefix(DNSConfiguration.maximumUpstreamServers))

        case .system:
            let usable = filterSystemDNSServers(systemDNSServers, serverIPv4: serverIPv4)
            guard !usable.isEmpty else { throw Failure.noUsableSystemDNSServers }
            return usable
        }
    }

    /// Filters a system resolver snapshot down to what is safe to forward to.
    ///
    /// The exclusions are not cosmetic. Forwarding to our own listen address would make
    /// dnsmasq query itself, and a loopback entry points at whatever resolver is running on
    /// this Mac — which, once a session is up, may well be us. Either creates a query loop.
    static func filterSystemDNSServers(
        _ servers: [IPv4Address],
        serverIPv4: IPv4Address
    ) -> [IPv4Address] {
        var seen: Set<IPv4Address> = []
        var usable: [IPv4Address] = []

        for server in servers {
            guard server != serverIPv4 else { continue }
            guard !server.isUnspecified, !server.isLoopback else { continue }
            guard server.isAssignableHostAddress else { continue }
            guard seen.insert(server).inserted else { continue }

            usable.append(server)
            if usable.count == DNSConfiguration.maximumUpstreamServers { break }
        }
        return usable
    }

    // MARK: - Host entries

    private static func resolveHostEntries(
        records: [LocalDNSRecord],
        localDomain: String
    ) throws(Failure) -> [HostEntry] {
        var byName: [String: (address: IPv4Address, names: [String])] = [:]

        for record in records where record.enabled {
            guard case .success(let resolved) = Hostname.resolve(
                record.hostname, localDomain: localDomain
            ) else {
                // Unreachable: ConfigurationValidator already rejected bad host names. Failing
                // rather than skipping means a future change that lets one slip through is
                // caught here instead of silently dropping a record the user configured.
                throw Failure.configuration([])
            }
            // Exact duplicates collapse; conflicting ones were already rejected.
            byName[resolved.fullyQualified] = (record.ipv4Address, resolved.hostsFileNames)
        }

        // Sorted by lowercase hostname so the same input always produces
        // byte-identical output.
        return byName.keys.sorted().compactMap { name in
            byName[name].map { HostEntry(address: $0.address, names: $0.names) }
        }
    }
}
