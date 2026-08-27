import Foundation
import Testing
import MacNetModels
@testable import MacNetLogging

/// Log classification coverage (ticket §24.1 "Log Tests").
///
/// The inputs are real dnsmasq output, because the whole value of the category filter is that
/// an engineer can narrow a busy log to "just the DHCP conversation" and trust that nothing
/// was left out.
@Suite("Log classifier")
struct LogClassifierTests {

    @Test("classifies the DHCP conversation",
          arguments: [
            "dnsmasq-dhcp[421]: DHCPDISCOVER(en7) 00:11:22:33:44:55",
            "dnsmasq-dhcp[421]: DHCPOFFER(en7) 192.168.50.10 00:11:22:33:44:55",
            "dnsmasq-dhcp[421]: DHCPREQUEST(en7) 192.168.50.10 00:11:22:33:44:55",
            "dnsmasq-dhcp[421]: DHCPACK(en7) 192.168.50.10 00:11:22:33:44:55 bmc01",
            "dnsmasq-dhcp[421]: DHCPNAK(en7) 192.168.50.99 00:11:22:33:44:55 wrong address",
            "dnsmasq-dhcp[421]: DHCPRELEASE(en7) 192.168.50.10 00:11:22:33:44:55",
          ])
    func classifiesDHCP(line: String) {
        // The decorated form matters: DHCPACK(en7) must tokenize to `dhcpack`, so brackets
        // have to be word boundaries.
        #expect(LogClassifier.category(for: line) == .dhcp)
    }

    @Test("classifies DNS activity",
          arguments: [
            "dnsmasq[421]: query[A] bmc01.lab.test from 192.168.50.20",
            "dnsmasq[421]: forwarded example.com to 1.1.1.1",
            "dnsmasq[421]: reply example.com is 93.184.216.34",
            "dnsmasq[421]: cached example.com is 93.184.216.34",
            "dnsmasq[421]: config bmc01.lab.test is 192.168.50.20",
          ])
    func classifiesDNS(line: String) {
        #expect(LogClassifier.category(for: line) == .dns)
    }

    @Test("classifies warnings")
    func classifiesWarnings() {
        #expect(LogClassifier.category(for: "dnsmasq[421]: warning: interface en7 does not currently exist") == .warning)
        #expect(LogClassifier.category(for: "dnsmasq[421]: LOUD WARNING: something") == .warning)
    }

    @Test("classifies errors",
          arguments: [
            "dnsmasq[421]: failed to create listening socket for 192.168.50.1",
            "dnsmasq[421]: cannot read /etc/example: No such file",
            "dnsmasq[421]: FATAL: cannot continue",
            "dnsmasq[421]: error at line 3 of dnsmasq.conf",
            "dnsmasq[421]: permission denied opening the lease file",
          ])
    func classifiesErrors(line: String) {
        #expect(LogClassifier.category(for: line) == .error)
    }

    @Test("everything else is System",
          arguments: [
            "dnsmasq[421]: started, version 2.93 cachesize 1000",
            "dnsmasq[421]: compile time options: IPv6 GNU-getopt DHCP",
            "dnsmasq-dhcp[421]: DHCP, IP range 192.168.50.10 -- 192.168.50.200, lease time 12h",
            "dnsmasq[421]: reading /var/db/com.bee.dnsmasqformac/.../hosts",
          ])
    func classifiesSystem(line: String) {
        #expect(LogClassifier.category(for: line) == .system)
    }

    @Test("matching is case-insensitive")
    func matchingIsCaseInsensitive() {
        #expect(LogClassifier.category(for: "DHCPACK(en7) 192.168.50.10") == .dhcp)
        #expect(LogClassifier.category(for: "dhcpack(en7) 192.168.50.10") == .dhcp)
        #expect(LogClassifier.category(for: "FAILED to bind") == .error)
        #expect(LogClassifier.category(for: "Failed to bind") == .error)
    }

    /// Substring matching would file each of these under the wrong category. These are the
    /// cases that make word-boundary matching worth the extra code.
    @Test("does not match keywords inside longer words")
    func doesNotMatchSubstrings() {
        // "cannot read config file" contains `config`, a DNS keyword. Filed as DNS, an
        // engineer filtering for errors would never see that their config could not be read.
        #expect(LogClassifier.category(for: "dnsmasq[421]: cannot read config file") == .error)

        // `errors` contains `error`, but a summary line is not itself an error.
        #expect(LogClassifier.category(for: "dnsmasq[421]: 0 errors so far") == .system)

        // `replying` contains `reply`.
        #expect(LogClassifier.category(for: "dnsmasq[421]: now replying-service is up") == .system)
    }

    @Test("severity wins over protocol when a line is both")
    func severityWinsOverProtocol() {
        // A failure mentioning DHCP must reach someone filtering for failures. Ticket §5.5
        // lists DHCP before Error; applied as precedence that would hide this line from the
        // Error filter, which is the one place it needs to appear.
        #expect(LogClassifier.category(for: "dnsmasq[421]: failed to send DHCPOFFER") == .error)
        #expect(LogClassifier.category(for: "dnsmasq[421]: cannot read config file") == .error)

        // dnsmasq labels its own non-fatal problems `warning:`; re-labelling them as errors
        // would cry wolf.
        #expect(LogClassifier.category(for: "dnsmasq[421]: warning: failed to access /x") == .warning)
    }

    @Test("an empty or whitespace line is System")
    func handlesEmptyLines() {
        #expect(LogClassifier.category(for: "") == .system)
        #expect(LogClassifier.category(for: "   ") == .system)
    }

    @Test("handles a line with invalid UTF-8 replacement characters")
    func handlesReplacementCharacters() {
        // A torn multi-byte sequence at the end of a file being written is normal. It must not
        // crash, and it must still classify.
        let line = "dnsmasq-dhcp[421]: DHCPACK(en7) 192.168.50.10 \u{FFFD}\u{FFFD}"
        #expect(LogClassifier.category(for: line) == .dhcp)
    }

    @Test("every category is reachable")
    func everyCategoryIsReachable() {
        // A category the classifier can never produce would be a filter chip that always
        // shows nothing.
        let samples = [
            "DHCPACK(en7) 1.2.3.4",
            "query[A] x.test from 1.2.3.4",
            "warning: something",
            "failed to bind",
            "started, version 2.93",
        ]
        #expect(Set(samples.map(LogClassifier.category)) == Set(LogCategory.allCases))
    }
}
