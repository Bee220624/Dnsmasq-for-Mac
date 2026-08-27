import Foundation
import Testing
import MacNetModels
@testable import MacNetDnsmasq

/// Golden-file coverage for the configuration generator.
///
/// These matter more than most tests: the generator's output is fed to a root process, and a
/// wrong or missing directive is the difference between serving one bench interface and
/// answering DHCP on the office network. Comparing whole files, byte for byte, is what makes
/// an accidental change impossible to miss in review.
///
/// The golden files are written from the specification, not recorded from the implementation.
/// A recorded golden only asserts that the code still does what it did, which is exactly the
/// property that is worthless when the code was wrong to begin with.
@Suite("Generated dnsmasq configuration")
struct GoldenConfigurationTests {

    // MARK: - Service combinations

    @Test("DHCP and DNS together match the specification")
    func dhcpAndDNS() throws {
        // The worked example from the specification, copied verbatim into the golden file.
        let generated = try Golden.generate(Golden.profile())
        try Golden.expectMatchesGolden(generated.configurationText, "dhcp-and-dns.conf")
    }

    @Test("DHCP only disables DNS with port=0 and suppresses the DNS option")
    func dhcpOnly() throws {
        // The specification: with DNS off, no upstream, local, domain, or expand-hosts directives
        // are emitted, and the DHCP DNS option is suppressed so clients are not pointed at a
        // closed port.
        let generated = try Golden.generate(Golden.profile(dnsEnabled: false))
        try Golden.expectMatchesGolden(generated.configurationText, "dhcp-only.conf")
    }

    @Test("DNS only emits no DHCP directives at all")
    func dnsOnly() throws {
        // The specification, including the absence of log-dhcp: logging DHCP with DHCP off would
        // produce a log file that never receives a line.
        let generated = try Golden.generate(Golden.profile(dhcpEnabled: false))
        try Golden.expectMatchesGolden(generated.configurationText, "dns-only.conf")
    }

    @Test("local-records-only mode keeps no-resolv but configures no upstream")
    func localRecordsOnly() throws {
        // no-resolv is still required: without it dnsmasq reads /etc/resolv.conf and quietly
        // starts forwarding, which is the exact opposite of what this mode is for.
        let generated = try Golden.generate(Golden.profile(upstreamMode: .localOnly))
        try Golden.expectMatchesGolden(generated.configurationText, "local-records-only.conf")
    }

    // MARK: - DHCP options

    @Test("an enabled router option carries the address")
    func routerEnabled() throws {
        let generated = try Golden.generate(Golden.profile(
            advertiseRouter: true, routerIPv4: "192.168.50.254"
        ))
        try Golden.expectMatchesGolden(generated.configurationText, "router-enabled.conf")
    }

    @Test("a disabled router option is suppressed, not omitted")
    func routerSuppressed() throws {
        // The specification: an option written with no value tells dnsmasq to send nothing.
        // Omitting the line entirely would let dnsmasq derive and send a default instead.
        let generated = try Golden.generate(Golden.profile(advertiseRouter: false))
        let lines = generated.configurationText.components(separatedBy: "\n")

        #expect(lines.contains("dhcp-option=option:router"))
        #expect(!lines.contains { $0.hasPrefix("dhcp-option=option:router,") })
    }

    @Test("the DNS option is suppressed when the Mac should not be advertised as a resolver")
    func dnsOptionSuppressed() throws {
        let generated = try Golden.generate(Golden.profile(advertiseLocalDNS: false))
        try Golden.expectMatchesGolden(
            generated.configurationText, "dns-option-suppressed.conf"
        )
    }

    @Test("authoritative mode is omitted when disabled")
    func authoritativeDisabled() throws {
        let generated = try Golden.generate(Golden.profile(authoritative: false))
        try Golden.expectMatchesGolden(
            generated.configurationText, "authoritative-disabled.conf"
        )
    }

    // MARK: - DNS options

    @Test("query logging adds log-queries=extra")
    func dnsQueryLogging() throws {
        // `extra` rather than plain `log-queries`: it adds the query id and the requesting
        // address, which is what makes the log usable for telling devices apart.
        let generated = try Golden.generate(Golden.profile(logQueries: true))
        try Golden.expectMatchesGolden(generated.configurationText, "dns-query-logging.conf")
    }

    // MARK: - Hosts file

    @Test("local A records are written sorted, with both name forms where applicable")
    func localARecords() throws {
        // Deliberately supplied out of order, and mixing relative with fully-qualified names.
        let generated = try Golden.generate(Golden.profile(records: [
            Golden.record("web", "192.168.50.21"),
            Golden.record("bmc01", "192.168.50.20"),
            Golden.record("switch01.other.test", "192.168.50.22"),
        ]))

        try Golden.expectMatchesGolden(generated.configurationText, "local-a-records.conf")
        try Golden.expectMatchesGolden(generated.hostsText, "local-a-records.hosts")
    }

    @Test("no records produces an empty hosts file, not a missing one")
    func emptyRecords() throws {
        // The config always references addn-hosts, so the file must exist and be readable.
        // An empty file is what dnsmasq expects; a missing one is a startup error.
        let generated = try Golden.generate(Golden.profile(records: []))
        #expect(generated.hostsText.isEmpty)
        #expect(generated.configurationText.contains("addn-hosts="))
    }

    @Test("a disabled record is not written")
    func disabledRecordsAreSkipped() throws {
        let generated = try Golden.generate(Golden.profile(records: [
            Golden.record("bmc01", "192.168.50.20"),
            Golden.record("ghost", "192.168.50.99", enabled: false),
        ]))
        #expect(generated.hostsText == "192.168.50.20 bmc01.lab.test bmc01\n")
    }

    @Test("a record comment never reaches either generated file")
    func commentsAreNeverWritten() throws {
        // The specification The comment is the one field with no character restrictions, which is
        // safe only because it has nowhere to go — this is the test that keeps it true.
        let generated = try Golden.generate(Golden.profile(records: [
            Golden.record("bmc01", "192.168.50.20", comment: "#\nserver=1.2.3.4\nmanagement"),
        ]))

        #expect(!generated.hostsText.contains("management"))
        #expect(!generated.hostsText.contains("server="))
        #expect(!generated.configurationText.contains("management"))
        #expect(generated.hostsText == "192.168.50.20 bmc01.lab.test bmc01\n")
    }

    @Test("duplicate identical records collapse to one line")
    func duplicateRecordsCollapse() throws {
        let generated = try Golden.generate(Golden.profile(records: [
            Golden.record("bmc01", "192.168.50.20"),
            Golden.record("BMC01", "192.168.50.20"),
        ]))
        #expect(generated.hostsText == "192.168.50.20 bmc01.lab.test bmc01\n")
    }

    // MARK: - Determinism

    @Test("the same input always produces byte-identical output")
    func outputIsDeterministic() throws {
        // Record order is deliberately shuffled between the two runs. Anything derived from
        // a Dictionary's iteration order or a Set would differ here.
        let first = try Golden.generate(Golden.profile(records: [
            Golden.record("web", "192.168.50.21"),
            Golden.record("bmc01", "192.168.50.20"),
            Golden.record("switch01", "192.168.50.22"),
        ]))
        let second = try Golden.generate(Golden.profile(records: [
            Golden.record("switch01", "192.168.50.22"),
            Golden.record("web", "192.168.50.21"),
            Golden.record("bmc01", "192.168.50.20"),
        ]))

        #expect(first.configurationText == second.configurationText)
        #expect(first.hostsText == second.hostsText)
    }

    @Test("both files use Unix line endings and end with a newline")
    func lineEndingsAreUnix() throws {
        let generated = try Golden.generate(Golden.profile(records: [
            Golden.record("bmc01", "192.168.50.20"),
        ]))

        #expect(!generated.configurationText.contains("\r"))
        #expect(!generated.hostsText.contains("\r"))
        #expect(generated.configurationText.hasSuffix("\n"))
        #expect(generated.hostsText.hasSuffix("\n"))
        // A file ending in a blank line would mean a stray empty section.
        #expect(!generated.configurationText.hasSuffix("\n\n"))
    }

    // MARK: - Lease duration formatting

    @Test("formats lease durations in the largest whole unit",
          arguments: [(600, "10m"), (3_600, "1h"), (28_800, "8h"), (43_200, "12h"),
                      (86_400, "1d"), (604_800, "7d"), (120, "2m"), (90, "90s"),
                      (5_400, "90m")])
    func formatsLeaseDurations(seconds: Int, expected: String) {
        // dnsmasq accepts raw seconds too, but a config a person can check at a glance is
        // worth the few lines it costs.
        #expect(DnsmasqConfigurationGenerator.formatLeaseDuration(seconds) == expected)
    }

    @Test("every UI lease preset renders as a readable duration",
          arguments: DHCPConfiguration.leaseDurationPresets)
    func presetsRenderReadably(seconds: Int) {
        let formatted = DnsmasqConfigurationGenerator.formatLeaseDuration(seconds)
        // No preset should fall through to raw seconds.
        #expect(!formatted.hasSuffix("s"), "preset \(seconds) rendered as \(formatted)")
    }
}
