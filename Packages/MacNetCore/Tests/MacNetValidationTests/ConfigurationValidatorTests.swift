import Foundation
import Testing
import MacNetModels
import MacNetValidation

@Suite("Configuration validation")
struct ConfigurationValidatorTests {

    private func issues(_ profile: NetworkProfile) -> [ValidationIssue] {
        ConfigurationValidator.validate(profile)
    }

    private func ids(_ profile: NetworkProfile) -> Set<String> {
        Set(issues(profile).map(\.id))
    }

    private func blocks(_ profile: NetworkProfile) -> Bool {
        ConfigurationValidator.hasBlockingIssues(issues(profile))
    }

    // MARK: - The shipping default

    @Test("the default profile is valid")
    func defaultProfileIsValid() {
        // The specification defines this exact configuration as what a new install starts with. If it
        // does not validate, every first-run experience begins with an error.
        #expect(issues(ProfileFixture.make()).isEmpty)
    }

    // MARK: - Server address

    @Test("rejects server addresses outside private-use space",
          arguments: ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "203.0.113.1"])
    func rejectsPublicServerAddress(address: String) {
        #expect(ids(ProfileFixture.make(serverIPv4: address)).contains("serverIPv4.notPrivate"))
    }

    @Test("rejects reserved server addresses with a specific reason",
          arguments: [("0.0.0.0", "serverIPv4.unspecified"),
                      ("127.0.0.1", "serverIPv4.loopback"),
                      ("169.254.1.1", "serverIPv4.linkLocal"),
                      ("224.0.0.1", "serverIPv4.multicast"),
                      ("255.255.255.255", "serverIPv4.broadcast")])
    func rejectsReservedServerAddress(address: String, expectedID: String) {
        #expect(ids(ProfileFixture.make(serverIPv4: address)).contains(expectedID))
    }

    @Test("rejects the network and broadcast addresses of the chosen subnet")
    func rejectsNetworkAndBroadcastServerAddress() {
        #expect(ids(ProfileFixture.make(serverIPv4: "192.168.50.0"))
            .contains("serverIPv4.isNetworkAddress"))
        #expect(ids(ProfileFixture.make(serverIPv4: "192.168.50.255", rangeEnd: "192.168.50.200"))
            .contains("serverIPv4.isBroadcastAddress"))
    }

    // MARK: - Prefix length

    @Test("rejects prefix lengths outside /8…/30", arguments: [0, 7, 31, 32])
    func rejectsPrefixOutOfRange(prefix: Int) {
        #expect(ids(ProfileFixture.make(prefixLength: prefix))
            .contains("prefixLength.outOfRange"))
    }

    @Test("warns about a very wide subnet without blocking it")
    func warnsAboutWideSubnet() {
        let profile = ProfileFixture.make(
            serverIPv4: "10.0.0.1", prefixLength: 8,
            rangeStart: "10.0.0.10", rangeEnd: "10.0.0.200"
        )
        let found = issues(profile)

        #expect(found.contains { $0.id == "prefixLength.veryWide" && $0.severity == .warning })
        // The specification: warnings are shown but never prevent Start.
        #expect(!ConfigurationValidator.hasBlockingIssues(found))
    }

    // MARK: - DHCP range

    @Test("rejects an inverted range")
    func rejectsInvertedRange() {
        #expect(ids(ProfileFixture.make(rangeStart: "192.168.50.200", rangeEnd: "192.168.50.10"))
            .contains("dhcp.rangeInverted"))
    }

    @Test("accepts a single-address pool")
    func acceptsSingleAddressPool() {
        // The smallest legitimate pool: one device on the bench.
        #expect(issues(ProfileFixture.make(
            rangeStart: "192.168.50.10", rangeEnd: "192.168.50.10"
        )).isEmpty)
    }

    @Test("rejects a range outside the server's subnet")
    func rejectsRangeOutsideSubnet() {
        let found = ids(ProfileFixture.make(
            rangeStart: "192.168.51.10", rangeEnd: "192.168.51.200"
        ))
        #expect(found.contains("dhcp.rangeStartOutsideSubnet"))
        #expect(found.contains("dhcp.rangeEndOutsideSubnet"))
    }

    @Test("rejects a pool that would hand out the network or broadcast address")
    func rejectsNetworkAndBroadcastInPool() {
        #expect(ids(ProfileFixture.make(rangeStart: "192.168.50.0"))
            .contains("dhcp.rangeStartIsNetworkAddress"))
        #expect(ids(ProfileFixture.make(rangeEnd: "192.168.50.255"))
            .contains("dhcp.rangeEndIsBroadcastAddress"))
    }

    @Test("rejects a pool containing this Mac's own address")
    func rejectsPoolContainingServer() {
        // Leasing the server's address to a client produces an address conflict that is
        // genuinely hard to diagnose from the client side.
        #expect(ids(ProfileFixture.make(rangeStart: "192.168.50.1"))
            .contains("dhcp.rangeContainsServer"))
    }

    @Test("enforces the pool size limit")
    func enforcesPoolSizeLimit() {
        // Exactly at the limit: 10.0.0.1 through 10.0.4.0 is 1024 addresses inclusive.
        let atLimit = ProfileFixture.make(
            serverIPv4: "10.0.99.1", prefixLength: 16,
            rangeStart: "10.0.0.1", rangeEnd: "10.0.4.0"
        )
        #expect(atLimit.dhcpConfiguration.poolSize == DHCPConfiguration.maximumPoolSize)
        #expect(!ids(atLimit).contains("dhcp.poolTooLarge"))

        // One past it.
        let tooLarge = ProfileFixture.make(
            serverIPv4: "10.0.99.1", prefixLength: 16,
            rangeStart: "10.0.0.1", rangeEnd: "10.0.4.1"
        )
        #expect(tooLarge.dhcpConfiguration.poolSize == DHCPConfiguration.maximumPoolSize + 1)
        #expect(ids(tooLarge).contains("dhcp.poolTooLarge"))
    }

    // MARK: - Router option

    @Test("requires a router address when Advertise Router is on")
    func requiresRouterAddress() {
        #expect(ids(ProfileFixture.make(advertiseRouter: true, routerIPv4: nil))
            .contains("dhcp.routerMissing"))
    }

    @Test("rejects a router outside the subnet, in the pool, or unassignable")
    func rejectsBadRouter() {
        #expect(ids(ProfileFixture.make(advertiseRouter: true, routerIPv4: "192.168.51.1"))
            .contains("dhcp.routerOutsideSubnet"))
        #expect(ids(ProfileFixture.make(advertiseRouter: true, routerIPv4: "192.168.50.100"))
            .contains("dhcp.routerInsidePool"))
        #expect(ids(ProfileFixture.make(advertiseRouter: true, routerIPv4: "192.168.50.0"))
            .contains("dhcp.routerNotAssignable"))
    }

    @Test("accepts a router outside the pool but inside the subnet")
    func acceptsValidRouter() {
        #expect(issues(ProfileFixture.make(advertiseRouter: true, routerIPv4: "192.168.50.254"))
            .isEmpty)
    }

    @Test("allows the router to be this Mac, which is not required but is legitimate")
    func allowsRouterEqualToServer() {
        // The specification is explicit that the router need not equal the server address — and
        // equally, that it may.
        #expect(issues(ProfileFixture.make(advertiseRouter: true, routerIPv4: "192.168.50.1"))
            .isEmpty)
    }

    // MARK: - Lease duration

    @Test("enforces the lease duration range", arguments: [119, 0, -1, 604_801, 1_000_000])
    func rejectsLeaseDurationOutOfRange(seconds: Int) {
        #expect(ids(ProfileFixture.make(leaseSeconds: seconds))
            .contains("dhcp.leaseDurationOutOfRange"))
    }

    @Test("accepts every lease duration offered in the UI",
          arguments: DHCPConfiguration.leaseDurationPresets)
    func acceptsPresetLeaseDurations(seconds: Int) {
        // A preset the validator rejects would be a UI that offers an unusable choice.
        #expect(issues(ProfileFixture.make(leaseSeconds: seconds)).isEmpty)
    }

    // MARK: - DNS

    @Test("requires at least one custom upstream in custom mode")
    func requiresCustomUpstream() {
        #expect(ids(ProfileFixture.make(upstreamMode: .custom, customUpstreams: []))
            .contains("dns.customUpstreamEmpty"))
    }

    @Test("caps and de-duplicates custom upstreams")
    func capsCustomUpstreams() {
        #expect(ids(ProfileFixture.make(
            upstreamMode: .custom,
            customUpstreams: ["1.1.1.1", "8.8.8.8", "9.9.9.9", "1.0.0.1", "8.8.4.4"]
        )).contains("dns.customUpstreamTooMany"))

        #expect(ids(ProfileFixture.make(
            upstreamMode: .custom, customUpstreams: ["1.1.1.1", "1.1.1.1"]
        )).contains("dns.customUpstreamDuplicate"))
    }

    @Test("does not require upstreams in system or local-only mode")
    func otherModesNeedNoUpstreams() {
        #expect(issues(ProfileFixture.make(upstreamMode: .system)).isEmpty)
        #expect(issues(ProfileFixture.make(upstreamMode: .localOnly)).isEmpty)
    }

    @Test("rejects the same name mapped to two different addresses")
    func rejectsConflictingRecords() {
        // dnsmasq cannot resolve this preference; it would answer inconsistently.
        let profile = ProfileFixture.make(records: [
            ProfileFixture.record("bmc01", "192.168.50.20"),
            ProfileFixture.record("bmc01", "192.168.50.21"),
        ])
        #expect(issues(profile).contains { $0.id.hasPrefix("dns.record.conflict") })
    }

    @Test("allows the same name repeated with the same address")
    func allowsDuplicateIdenticalRecords() {
        // Redundant, but not contradictory — the hosts generator de-duplicates it.
        let profile = ProfileFixture.make(records: [
            ProfileFixture.record("bmc01", "192.168.50.20"),
            ProfileFixture.record("bmc01", "192.168.50.20"),
        ])
        #expect(issues(profile).isEmpty)
    }

    @Test("ignores disabled records entirely")
    func ignoresDisabledRecords() {
        // A disabled row is never written, so an invalid one must not block Start — otherwise
        // the only way past a bad row would be to delete it.
        let profile = ProfileFixture.make(records: [
            ProfileFixture.record("this is not a hostname", "192.168.50.20", enabled: false),
        ])
        #expect(issues(profile).isEmpty)
    }

    @Test("rejects an invalid hostname in an enabled record")
    func rejectsInvalidRecordHostname() {
        let profile = ProfileFixture.make(records: [
            ProfileFixture.record("bmc 01", "192.168.50.20"),
        ])
        #expect(issues(profile).contains { $0.id.hasPrefix("dns.record.hostname") })
    }

    // MARK: - Cross-cutting

    @Test("rejects a configuration with nothing enabled")
    func rejectsNoServicesEnabled() {
        // Starting with neither DHCP nor DNS would run dnsmasq with
        // nothing to do.
        #expect(ids(ProfileFixture.make(dhcpEnabled: false, dnsEnabled: false))
            .contains("services.noneEnabled"))
    }

    @Test("does not validate DHCP fields when DHCP is off")
    func skipsDisabledDHCP() {
        // An out-of-subnet range that will never be used must not block a DNS-only session.
        #expect(issues(ProfileFixture.make(
            dhcpEnabled: false, rangeStart: "10.9.9.9", rangeEnd: "10.9.9.99"
        )).isEmpty)
    }

    @Test("does not validate DNS fields when DNS is off")
    func skipsDisabledDNS() {
        #expect(issues(ProfileFixture.make(dnsEnabled: false, localDomain: "!!!invalid!!!"))
            .isEmpty)
    }

    @Test("requires a profile name")
    func requiresName() {
        #expect(ids(ProfileFixture.make(name: "   ")).contains("profileName.empty"))
    }

    @Test("reports every independent problem at once")
    func reportsAllProblems() {
        // The user is filling in a form. Surfacing one error at a time turns configuring a
        // subnet into a guessing game.
        let profile = ProfileFixture.make(
            serverIPv4: "8.8.8.8",
            leaseSeconds: 10,
            dnsEnabled: true,
            localDomain: "lab.local"
        )
        let found = issues(profile)

        #expect(found.count >= 3)
        #expect(found.contains { $0.field == .serverIPv4 })
        #expect(found.contains { $0.field == .dhcpLeaseDuration })
        #expect(found.contains { $0.field == .dnsLocalDomain })
    }
}

@Suite("Default profile")
struct DefaultProfileTests {

    @Test("the first-launch profile validates cleanly")
    func defaultProfileValidates() {
        // A new install must not open onto an error. This is the exact configuration from
        // the specification
        let profile = NetworkProfile.makeDefault(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(ConfigurationValidator.validate(profile).isEmpty)
    }

    @Test("matches the specified values")
    func matchesSpecifiedValues() {
        let profile = NetworkProfile.makeDefault(now: Date(timeIntervalSince1970: 0))

        #expect(profile.name == "Direct Device / BMC")
        #expect(profile.schemaVersion == MacNetCoreInfo.schemaVersion)

        #expect(profile.interfaceConfiguration.serverIPv4.description == "192.168.50.1")
        #expect(profile.interfaceConfiguration.prefixLength == 24)
        #expect(profile.interfaceConfiguration.addTemporaryIPv4Alias)

        #expect(profile.dhcpConfiguration.rangeStart.description == "192.168.50.10")
        #expect(profile.dhcpConfiguration.rangeEnd.description == "192.168.50.200")
        #expect(profile.dhcpConfiguration.leaseDurationSeconds == 43_200)
        #expect(profile.dhcpConfiguration.authoritative)
        #expect(!profile.dhcpConfiguration.advertiseRouter)
        #expect(profile.dhcpConfiguration.routerIPv4 == nil)
        #expect(profile.dhcpConfiguration.advertiseLocalDNSServer)

        #expect(profile.dnsConfiguration.localDomain == "lab.test")
        #expect(profile.dnsConfiguration.upstreamMode == .system)
        #expect(!profile.dnsConfiguration.logQueries)
        #expect(profile.dnsConfiguration.records.isEmpty)

        // 192.168.50.10 through .200 inclusive.
        #expect(profile.dhcpConfiguration.poolSize == 191)
    }

    @Test("round-trips through JSON")
    func roundTripsThroughJSON() throws {
        let original = NetworkProfile.makeDefault(now: Date(timeIntervalSince1970: 1_700_000_000))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        #expect(try decoder.decode(NetworkProfile.self, from: data) == original)
    }

    @Test("addresses are stored as readable strings")
    func addressesAreReadable() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            NetworkProfile.makeDefault(now: Date(timeIntervalSince1970: 0))
        )
        let json = try #require(String(data: data, encoding: .utf8))

        // Profiles are meant to be readable, and repairable by hand in an emergency.
        #expect(json.contains("\"192.168.50.1\""))
        #expect(json.contains("\"1970-01-01T00:00:00Z\""))
    }
}

@Suite("Preflight report")
struct PreflightReportTests {

    @Test("a pending report lists every check")
    func pendingListsAllChecks() {
        // The UI shows the whole checklist up front, so the user can see what will be checked
        // rather than only what failed.
        let report = PreflightReport.pending(at: Date(timeIntervalSince1970: 0))

        #expect(report.checks.count == PreflightCheck.allCases.count)
        #expect(report.checks.allSatisfy { $0.status == .pending })
        #expect(!report.hasBlockingIssues)
    }

    @Test("only errors block Start")
    func onlyErrorsBlock() {
        // The specification: warnings must be shown clearly but must never prevent Start. Link
        // Down is the motivating case — the device may simply not be powered on yet.
        let warningOnly = PreflightReport(
            checks: [],
            issues: [PreflightIssue(
                id: "link.down", severity: .warning,
                title: "No Link", message: "The interface has no carrier."
            )],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(!warningOnly.hasBlockingIssues)
        #expect(warningOnly.warnings.count == 1)

        let withError = PreflightReport(
            checks: [],
            issues: [PreflightIssue(
                id: "port.inUse", severity: .error,
                title: "Port In Use", message: "UDP 67 is already bound."
            )],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(withError.hasBlockingIssues)
        #expect(withError.errors.count == 1)
    }
}
