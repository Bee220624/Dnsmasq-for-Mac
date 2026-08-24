import Foundation
import Testing
import MacNetModels
@testable import MacNetLeases

/// Lease parsing coverage (ticket §24.1 "Lease Parser Tests").
///
/// The file being parsed is written by another process while it is read, so malformed input is
/// normal rather than exceptional — most of these tests are about not losing good data when
/// some of it is bad.
@Suite("Lease parser")
struct DnsmasqLeaseParserTests {

    private let parser = DnsmasqLeaseParser()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("parses an ordinary lease")
    func parsesNormalLease() throws {
        let result = parser.parse(
            "1787558400 00:11:22:33:44:55 192.168.50.10 bmc01 01:00:11:22:33:44:55\n",
            now: now
        )

        #expect(result.malformedLines.isEmpty)
        let lease = try #require(result.leases.first)
        #expect(lease.macAddress == "00:11:22:33:44:55")
        #expect(lease.ipv4Address.description == "192.168.50.10")
        #expect(lease.hostname == "bmc01")
        #expect(lease.clientID == "01:00:11:22:33:44:55")
        #expect(lease.status == .active)
        #expect(lease.expiresAt == Date(timeIntervalSince1970: 1_787_558_400))
    }

    @Test("expiry zero means the lease never expires")
    func parsesInfiniteLease() throws {
        let result = parser.parse("0 aa:bb:cc:dd:ee:ff 192.168.50.11 * *\n", now: now)

        let lease = try #require(result.leases.first)
        #expect(lease.status == .infinite)
        #expect(lease.expiresAt == nil)
        // `*` is dnsmasq's marker for an absent field, not a hostname.
        #expect(lease.hostname == nil)
        #expect(lease.clientID == nil)
    }

    @Test("an expiry in the past is reported as expired")
    func detectsExpiredLease() throws {
        let result = parser.parse(
            "1600000000 00:11:22:33:44:55 192.168.50.10 old *\n", now: now
        )
        #expect(try #require(result.leases.first).status == .expired)
    }

    @Test("tolerates extra whitespace between fields")
    func toleratesExtraWhitespace() throws {
        let result = parser.parse(
            "1787558400   00:11:22:33:44:55    192.168.50.10   bmc01   *\n", now: now
        )
        #expect(result.malformedLines.isEmpty)
        #expect(try #require(result.leases.first).hostname == "bmc01")
    }

    @Test("ignores trailing fields it does not need")
    func ignoresExtraFields() throws {
        // dnsmasq appends more for some client types. Rejecting the line would lose a lease
        // that is perfectly readable.
        let result = parser.parse(
            "1787558400 00:11:22:33:44:55 192.168.50.10 bmc01 01:aa extra stuff\n", now: now
        )
        #expect(result.malformedLines.isEmpty)
        #expect(result.leases.count == 1)
    }

    @Test("an empty file yields no leases and no complaints")
    func parsesEmptyFile() {
        // The normal state before the first client appears — not an error.
        #expect(parser.parse("", now: now).leases.isEmpty)
        #expect(parser.parse("\n\n  \n", now: now).malformedLines.isEmpty)
    }

    @Test("one malformed line does not lose the others")
    func oneBadLineDoesNotLoseTheFile() {
        // The file is being written while it is read, so a torn final line is routine. Losing
        // the whole table at that moment would be worst exactly when it is being watched.
        let text = """
        1787558400 00:11:22:33:44:55 192.168.50.10 bmc01 *
        this line is nonsense
        1787558400 aa:bb:cc:dd:ee:ff 192.168.50.11 switch01 *
        """

        let result = parser.parse(text, now: now)
        #expect(result.leases.count == 2)
        #expect(result.malformedLines.count == 1)
        #expect(result.malformedLines.first?.lineNumber == 2)
    }

    @Test("rejects lines with individually malformed fields",
          arguments: [
            "notanumber 00:11:22:33:44:55 192.168.50.10 bmc01 *",   // expiry
            "1787558400 not-a-mac 192.168.50.10 bmc01 *",           // MAC
            "1787558400 00:11:22:33:44 192.168.50.10 bmc01 *",      // MAC too short
            "1787558400 00:11:22:33:44:55:66 192.168.50.10 x *",    // MAC too long
            "1787558400 00:11:22:33:44:zz 192.168.50.10 bmc01 *",   // MAC not hex
            "1787558400 00:11:22:33:44:55 999.1.1.1 bmc01 *",       // IP out of range
            "1787558400 00:11:22:33:44:55 010.1.1.1 bmc01 *",       // IP with leading zero
            "1787558400 00:11:22:33:44:55 bmc01 *",                 // too few fields
            "-1 00:11:22:33:44:55 192.168.50.10 bmc01 *",           // negative expiry
          ])
    func rejectsMalformedFields(line: String) {
        let result = parser.parse(line, now: now)
        #expect(result.leases.isEmpty, "should not have parsed: \(line)")
        #expect(result.malformedLines.count == 1)
    }

    @Test("normalizes hardware addresses to lowercase")
    func normalizesMAC() throws {
        let result = parser.parse(
            "1787558400 AA:BB:CC:DD:EE:FF 192.168.50.10 bmc01 *\n", now: now
        )
        // The lease id is built from the MAC. A case difference would split one device into
        // two rows that renew alternately.
        #expect(try #require(result.leases.first).macAddress == "aa:bb:cc:dd:ee:ff")
    }

    @Test("pads single-digit octets so the rendered form is uniform")
    func padsShortOctets() {
        #expect(DnsmasqLeaseParser.normalizedMAC("0:1:2:3:4:5") == "00:01:02:03:04:05")
        #expect(DnsmasqLeaseParser.normalizedMAC("a:bb:c:dd:e:ff") == "0a:bb:0c:dd:0e:ff")
    }

    @Test("sorts by numeric address, not by text")
    func sortsNumerically() {
        let text = """
        1787558400 00:11:22:33:44:01 192.168.50.10 a *
        1787558400 00:11:22:33:44:02 192.168.50.9 b *
        1787558400 00:11:22:33:44:03 192.168.50.100 c *
        """

        // Sorted as text, .10 would precede .9. The leases table sorts by address, so this
        // being wrong would be visible on screen.
        #expect(parser.parse(text, now: now).leases.map(\.ipv4Address.description)
            == ["192.168.50.9", "192.168.50.10", "192.168.50.100"])
    }

    @Test("gives each lease a stable identity built from MAC and address")
    func leaseIdentityIsStable() throws {
        let line = "1787558400 00:11:22:33:44:55 192.168.50.10 bmc01 *\n"

        // Neither field alone is unique: one MAC holds different addresses over time, one
        // address is reused across devices. The pair keeps rows stable across renewals.
        let first = try #require(parser.parse(line, now: now).leases.first)
        let second = try #require(parser.parse(line, now: now).leases.first)
        #expect(first.id == second.id)
        #expect(first.id == "00:11:22:33:44:55|192.168.50.10")
    }

    @Test("reports remaining time without reading the clock")
    func computesRemaining() throws {
        let lease = try #require(parser.parse(
            "1700000600 00:11:22:33:44:55 192.168.50.10 bmc01 *\n", now: now
        ).leases.first)

        // Computed from a passed-in `now` so the UI can tick every second without re-reading
        // the file (ticket §5.4), and so this is testable at all.
        #expect(lease.remaining(asOf: now) == 600)
        #expect(lease.remaining(asOf: Date(timeIntervalSince1970: 1_700_000_700)) == nil)
    }

    @Test("an infinite lease has no remaining time")
    func infiniteLeaseHasNoRemaining() throws {
        let lease = try #require(parser.parse(
            "0 00:11:22:33:44:55 192.168.50.10 bmc01 *\n", now: now
        ).leases.first)
        #expect(lease.remaining(asOf: now) == nil)
    }

    @Test("handles a full pool without difficulty")
    func handlesFullPool() {
        // 191 leases is the shipping default pool. Well under the size cap, but worth
        // confirming the parser is linear and does not choke.
        let lines = (10...200).map { index in
            "1787558400 00:11:22:33:44:\(String(format: "%02x", index % 256)) "
                + "192.168.50.\(index) host\(index) *"
        }
        let result = parser.parse(lines.joined(separator: "\n"), now: now)

        #expect(result.leases.count == 191)
        #expect(result.malformedLines.isEmpty)
    }
}
