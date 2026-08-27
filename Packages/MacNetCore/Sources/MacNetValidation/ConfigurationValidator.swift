import Foundation
import MacNetModels

/// Which field an issue belongs to, so the UI can attach the message to the right control
/// (requires form errors to be associated with their field not floated /// somewhere generic).
public enum ValidationField: String, Sendable, Equatable, CaseIterable {
    case profileName
    case serverIPv4
    case prefixLength
    case dhcpEnabled
    case dhcpRangeStart
    case dhcpRangeEnd
    case dhcpLeaseDuration
    case dhcpRouter
    case dnsEnabled
    case dnsLocalDomain
    case dnsUpstreamServers
    case dnsRecords
    case services
}

public enum ValidationSeverity: String, Sendable, Equatable, Comparable {
    case warning
    case error

    public static func < (lhs: ValidationSeverity, rhs: ValidationSeverity) -> Bool {
        lhs == .warning && rhs == .error
    }
}

/// One problem found in a configuration.
public struct ValidationIssue: Sendable, Equatable, Identifiable {
    public let id: String
    public let field: ValidationField
    public let severity: ValidationSeverity
    public let message: String

    public init(id: String, field: ValidationField, severity: ValidationSeverity, message: String) {
        self.id = id
        self.field = field
        self.severity = severity
        self.message = message
    }
}

/// Validates a complete profile against every rule in the specification
///
/// ## Why this returns a list instead of throwing
///
/// The user is filling in a form. Reporting one problem, then the next after they fix it, is
/// a miserable way to configure a subnet. Every independent rule is evaluated and all findings
/// are returned at once.
///
/// ## Why this lives in the shared core
///
/// The app runs it for live feedback, and the helper runs the *same code* on the request it
/// receives. The specification is explicit that helper-side validation is the real security boundary
/// and that app-side results must never be trusted — sharing the implementation means the two
/// cannot disagree about what "valid" means, while the helper still re-derives the answer
/// itself rather than accepting the app's word for it.
public enum ConfigurationValidator {

    public static func validate(_ profile: NetworkProfile) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        issues.append(contentsOf: validateName(profile.name))

        let interface = profile.interfaceConfiguration
        issues.append(contentsOf: validatePrefixLength(interface.prefixLength))
        issues.append(contentsOf: validateServerAddress(interface))

        // Range checks are meaningless without a well-formed subnet, and running them anyway
        // would bury the real problem under a cascade of derived complaints.
        let subnet = interface.subnet

        if profile.dhcpConfiguration.enabled {
            issues.append(contentsOf: validateDHCP(
                profile.dhcpConfiguration,
                serverIPv4: interface.serverIPv4,
                subnet: subnet
            ))
        }

        if profile.dnsConfiguration.enabled {
            issues.append(contentsOf: validateDNS(profile.dnsConfiguration))
        }

        if !profile.dhcpConfiguration.enabled && !profile.dnsConfiguration.enabled {
            issues.append(ValidationIssue(
                id: "services.noneEnabled",
                field: .services,
                severity: .error,
                message: "Enable DHCP, DNS, or both. There is nothing to start otherwise."
            ))
        }

        return issues
    }

    /// Convenience for gating Start: warnings are shown but never block.
    public static func hasBlockingIssues(_ issues: [ValidationIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }

    // MARK: - Name

    private static func validateName(_ name: String) -> [ValidationIssue] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return [] }
        return [ValidationIssue(
            id: "profileName.empty",
            field: .profileName,
            severity: .error,
            message: "Give the profile a name."
        )]
    }

    // MARK: - Addressing

    private static func validatePrefixLength(_ prefixLength: Int) -> [ValidationIssue] {
        guard IPv4Subnet.allowedPrefixLengths.contains(prefixLength) else {
            // /31 and /32 are called out by name: they are valid CIDR that a user might
            // reasonably try, and "out of range" alone would not explain why.
            let explanation = (prefixLength == 31 || prefixLength == 32)
                ? "A /\(prefixLength) subnet has no room for both a server address and a DHCP pool."
                : "Use a prefix length between /8 and /30."
            return [ValidationIssue(
                id: "prefixLength.outOfRange",
                field: .prefixLength,
                severity: .error,
                message: explanation
            )]
        }

        guard prefixLength < IPv4Subnet.warnBelowPrefixLength else { return [] }
        return [ValidationIssue(
            id: "prefixLength.veryWide",
            field: .prefixLength,
            severity: .warning,
            message: "A /\(prefixLength) subnet is unusually large for a lab network. "
                + "Check this is what you meant."
        )]
    }

    private static func validateServerAddress(
        _ configuration: InterfaceConfiguration
    ) -> [ValidationIssue] {
        let address = configuration.serverIPv4
        var issues: [ValidationIssue] = []

        func reject(_ id: String, _ message: String) {
            issues.append(ValidationIssue(
                id: id, field: .serverIPv4, severity: .error, message: message
            ))
        }

        if address.isUnspecified {
            reject("serverIPv4.unspecified", "0.0.0.0 is not a usable server address.")
        } else if address.isLoopback {
            reject("serverIPv4.loopback", "A loopback address cannot serve a network.")
        } else if address.isLinkLocal {
            reject("serverIPv4.linkLocal",
                   "169.254.x.x is assigned by macOS itself and cannot be used here.")
        } else if address.isMulticast {
            reject("serverIPv4.multicast", "A multicast address cannot be a server address.")
        } else if address.isLimitedBroadcast {
            reject("serverIPv4.broadcast", "255.255.255.255 is not a usable server address.")
        } else if !address.isPrivateUse {
            // Refusing public space is a guardrail against numbering a lab out of an address
            // block that belongs to someone else.
            reject("serverIPv4.notPrivate",
                   "Use a private address: 10.x.x.x, 172.16–31.x.x, or 192.168.x.x.")
        }

        // Network and broadcast checks need the subnet, which needs a valid prefix. If the
        // prefix is wrong, that issue is already reported and this would only add noise.
        if let subnet = configuration.subnet, issues.isEmpty {
            if address == subnet.networkAddress {
                reject("serverIPv4.isNetworkAddress",
                       "\(address) is the network address of \(subnet.networkAddress)"
                        + "/\(subnet.prefixLength) and cannot be assigned to a host.")
            } else if address == subnet.broadcastAddress {
                reject("serverIPv4.isBroadcastAddress",
                       "\(address) is the broadcast address of this subnet "
                        + "and cannot be assigned to a host.")
            }
        }

        return issues
    }

    // MARK: - DHCP

    private static func validateDHCP(
        _ configuration: DHCPConfiguration,
        serverIPv4: IPv4Address,
        subnet: IPv4Subnet?
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        func reject(_ id: String, _ field: ValidationField, _ message: String) {
            issues.append(ValidationIssue(
                id: id, field: field, severity: .error, message: message
            ))
        }

        if !DHCPConfiguration.allowedLeaseDurationSeconds.contains(
            configuration.leaseDurationSeconds
        ) {
            reject("dhcp.leaseDurationOutOfRange", .dhcpLeaseDuration,
                   "Lease duration must be between 2 minutes and 7 days.")
        }

        guard let subnet else { return issues }

        let start = configuration.rangeStart
        let end = configuration.rangeEnd

        guard start <= end else {
            reject("dhcp.rangeInverted", .dhcpRangeStart,
                   "The start of the range must not be higher than the end.")
            return issues
        }

        var rangeIsSane = true
        if !subnet.contains(start) {
            reject("dhcp.rangeStartOutsideSubnet", .dhcpRangeStart,
                   "\(start) is outside \(subnet.networkAddress)/\(subnet.prefixLength).")
            rangeIsSane = false
        }
        if !subnet.contains(end) {
            reject("dhcp.rangeEndOutsideSubnet", .dhcpRangeEnd,
                   "\(end) is outside \(subnet.networkAddress)/\(subnet.prefixLength).")
            rangeIsSane = false
        }
        if start == subnet.networkAddress {
            reject("dhcp.rangeStartIsNetworkAddress", .dhcpRangeStart,
                   "The pool cannot begin at the network address.")
            rangeIsSane = false
        }
        if end == subnet.broadcastAddress {
            reject("dhcp.rangeEndIsBroadcastAddress", .dhcpRangeEnd,
                   "The pool cannot end at the broadcast address.")
            rangeIsSane = false
        }

        if rangeIsSane {
            // Handing a client the server's own address produces a conflict that is genuinely
            // hard to diagnose from the client side.
            if start <= serverIPv4 && serverIPv4 <= end {
                reject("dhcp.rangeContainsServer", .dhcpRangeStart,
                       "The pool includes this Mac's own address, \(serverIPv4). "
                        + "Move the pool or change the server address.")
            }

            if let size = start.addressCount(through: end) {
                if size > DHCPConfiguration.maximumPoolSize {
                    reject("dhcp.poolTooLarge", .dhcpRangeEnd,
                           "The pool holds \(size) addresses. The maximum is "
                            + "\(DHCPConfiguration.maximumPoolSize).")
                }
            } else {
                reject("dhcp.poolEmpty", .dhcpRangeEnd, "The pool contains no addresses.")
            }
        }

        issues.append(contentsOf: validateRouter(
            configuration, subnet: subnet, start: start, end: end
        ))

        return issues
    }

    private static func validateRouter(
        _ configuration: DHCPConfiguration,
        subnet: IPv4Subnet,
        start: IPv4Address,
        end: IPv4Address
    ) -> [ValidationIssue] {
        guard configuration.advertiseRouter else { return [] }

        func reject(_ id: String, _ message: String) -> ValidationIssue {
            ValidationIssue(id: id, field: .dhcpRouter, severity: .error, message: message)
        }

        guard let router = configuration.routerIPv4 else {
            return [reject("dhcp.routerMissing",
                           "Enter the router address, or turn off Advertise Router.")]
        }

        if !subnet.contains(router) {
            return [reject("dhcp.routerOutsideSubnet",
                           "\(router) is outside \(subnet.networkAddress)/\(subnet.prefixLength). "
                            + "Clients could not reach it.")]
        }
        if router == subnet.networkAddress || router == subnet.broadcastAddress {
            return [reject("dhcp.routerNotAssignable",
                           "\(router) is the network or broadcast address of this subnet.")]
        }
        if start <= router && router <= end {
            // The pool would eventually hand the router's address to a client.
            return [reject("dhcp.routerInsidePool",
                           "\(router) is inside the DHCP pool and could be leased to a client.")]
        }

        return []
    }

    // MARK: - DNS

    private static func validateDNS(_ configuration: DNSConfiguration) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        let localDomain: String
        switch DomainName.validateLocalDomain(configuration.localDomain) {
        case .success(let normalized):
            localDomain = normalized
        case .failure(let failure):
            issues.append(ValidationIssue(
                id: "dns.localDomain.\(failure.rawValue)",
                field: .dnsLocalDomain,
                severity: .error,
                message: message(for: failure)
            ))
            // Host names are qualified against the local domain, so without a usable one
            // every record would report a spurious failure.
            return issues
        }

        if configuration.upstreamMode == .custom {
            issues.append(contentsOf: validateCustomUpstreams(configuration.customUpstreamServers))
        }

        issues.append(contentsOf: validateRecords(
            configuration.records, localDomain: localDomain
        ))

        return issues
    }

    private static func validateCustomUpstreams(
        _ servers: [IPv4Address]
    ) -> [ValidationIssue] {
        func reject(_ id: String, _ message: String) -> ValidationIssue {
            ValidationIssue(
                id: id, field: .dnsUpstreamServers, severity: .error, message: message
            )
        }

        guard !servers.isEmpty else {
            return [reject("dns.customUpstreamEmpty",
                           "Add at least one upstream DNS server, or choose a different mode.")]
        }
        guard servers.count <= DNSConfiguration.maximumUpstreamServers else {
            return [reject("dns.customUpstreamTooMany",
                           "At most \(DNSConfiguration.maximumUpstreamServers) upstream servers.")]
        }

        var issues: [ValidationIssue] = []
        for server in servers where !server.isAssignableHostAddress {
            issues.append(reject("dns.customUpstreamUnusable.\(server)",
                                 "\(server) is not a usable DNS server address."))
        }
        if Set(servers).count != servers.count {
            issues.append(reject("dns.customUpstreamDuplicate",
                                 "Remove duplicate upstream servers."))
        }
        return issues
    }

    private static func validateRecords(
        _ records: [LocalDNSRecord],
        localDomain: String
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var addressByName: [String: IPv4Address] = [:]

        for record in records where record.enabled {
            if record.comment.count > LocalDNSRecord.maximumCommentLength {
                issues.append(ValidationIssue(
                    id: "dns.record.commentTooLong.\(record.id)",
                    field: .dnsRecords,
                    severity: .error,
                    message: "Comments are limited to "
                        + "\(LocalDNSRecord.maximumCommentLength) characters."
                ))
            }

            switch Hostname.resolve(record.hostname, localDomain: localDomain) {
            case .failure(let failure):
                issues.append(ValidationIssue(
                    id: "dns.record.hostname.\(record.id)",
                    field: .dnsRecords,
                    severity: .error,
                    message: "'\(record.hostname)': \(message(for: failure))"
                ))

            case .success(let resolved):
                // The same name mapping to two addresses is not a preference dnsmasq can
                // resolve — it would answer inconsistently.
                if let existing = addressByName[resolved.fullyQualified],
                   existing != record.ipv4Address {
                    issues.append(ValidationIssue(
                        id: "dns.record.conflict.\(record.id)",
                        field: .dnsRecords,
                        severity: .error,
                        message: "\(resolved.fullyQualified) is defined twice with different "
                            + "addresses (\(existing) and \(record.ipv4Address))."
                    ))
                } else {
                    addressByName[resolved.fullyQualified] = record.ipv4Address
                }

                if !record.ipv4Address.isAssignableHostAddress {
                    issues.append(ValidationIssue(
                        id: "dns.record.address.\(record.id)",
                        field: .dnsRecords,
                        severity: .error,
                        message: "\(record.ipv4Address) is not a usable host address."
                    ))
                }
            }
        }

        return issues
    }

    // MARK: - Messages

    private static func message(for failure: DomainName.Failure) -> String {
        switch failure {
        case .empty: "Enter a local domain, for example \(DomainName.defaultLocalDomain)."
        case .tooLong: "A domain name may be at most \(DomainName.maximumLength) characters."
        case .labelEmpty: "The domain contains an empty part."
        case .labelTooLong:
            "Each part may be at most \(DomainName.maximumLabelLength) characters."
        case .labelHasInvalidCharacter:
            "Use only letters, digits, and hyphens."
        case .labelStartsWithHyphen: "A part cannot start with a hyphen."
        case .labelEndsWithHyphen: "A part cannot end with a hyphen."
        case .missingDot:
            "Use a domain with at least two parts, for example \(DomainName.defaultLocalDomain)."
        case .reservedForMulticastDNS:
            ".local is reserved for Bonjour and cannot be served here. Try .test instead."
        }
    }

    private static func message(for failure: Hostname.Failure) -> String {
        switch failure {
        case .empty: "enter a host name"
        case .tooLong: "the name is too long"
        case .containsWhitespace: "a host name cannot contain spaces"
        case .containsForbiddenCharacter: "use only letters, digits, hyphens, and dots"
        case .labelEmpty: "the name contains an empty part"
        case .labelTooLong:
            "each part may be at most \(DomainName.maximumLabelLength) characters"
        case .labelStartsWithHyphen: "a part cannot start with a hyphen"
        case .labelEndsWithHyphen: "a part cannot end with a hyphen"
        }
    }
}
