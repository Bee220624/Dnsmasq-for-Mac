import Foundation
import Testing
import MacNetModels

@Suite("IPv4 address parsing")
struct IPv4AddressTests {

    @Test("parses ordinary dotted-quad addresses",
          arguments: ["192.168.50.1", "10.0.0.1", "172.16.0.1", "0.0.0.0", "255.255.255.255",
                      "1.2.3.4", "8.8.8.8"])
    func parsesValidAddresses(text: String) throws {
        let address = try #require(IPv4Address(text))
        // Round-tripping proves the parse and the rendering agree, not merely that parsing
        // returned something.
        #expect(address.description == text)
    }

    @Test("rejects malformed text",
          arguments: [
            "",                  // empty
            "1.2.3",             // too few octets
            "1.2.3.4.5",         // too many octets
            "1.2.3.256",         // octet out of range
            "1.2.3.-1",          // negative octet
            "1.2.3.",            // trailing dot
            ".1.2.3",            // leading dot
            "1..2.3",            // empty octet
            "1.2.3.4a",          // trailing garbage
            "0x7f.0.0.1",        // hexadecimal
            "localhost",         // hostname
            "::1",               // IPv6
            "2001:db8::1",       // IPv6
          ])
    func rejectsMalformedText(text: String) {
        #expect(IPv4Address(text) == nil)
    }

    @Test("rejects untrimmed whitespace rather than silently accepting it",
          arguments: [" 1.2.3.4", "1.2.3.4 ", "\t1.2.3.4", "1.2.3.4\n", "1.2. 3.4"])
    func rejectsWhitespace(text: String) {
        // The specification lists uncleaned whitespace as a rejection, not something to strip. A
        // field that quietly repairs its input teaches the user that spaces are fine, which
        // stops being true the moment the value reaches somewhere less forgiving.
        #expect(IPv4Address(text) == nil)
    }

    @Test("rejects a CIDR suffix in an address field", arguments: ["1.2.3.4/24", "192.168.1.0/24"])
    func rejectsCIDR(text: String) {
        #expect(IPv4Address(text) == nil)
    }

    /// macOS's own `inet_pton` accepts these and reads them as decimal, while many other
    /// parsers read a leading zero as octal — `010` becomes 8, not 10. These addresses are
    /// written into a dnsmasq configuration file and compared against interface addresses, so
    /// a value two parsers disagree about must never get that far.
    @Test("rejects leading zeros, which other parsers read as octal",
          arguments: ["010.1.1.1", "01.2.3.4", "1.2.3.04", "192.168.050.1", "00.0.0.0"])
    func rejectsLeadingZeros(text: String) {
        #expect(IPv4Address(text) == nil)
    }

    @Test("orders numerically, not lexicographically")
    func ordersNumerically() throws {
        let low = try #require(IPv4Address("192.168.50.9"))
        let high = try #require(IPv4Address("192.168.50.10"))

        // Sorted as text, "192.168.50.10" precedes "192.168.50.9". The lease table sorts by
        // address, so this being wrong would be visible on every screen.
        #expect(low < high)
    }

    @Test("classifies reserved ranges")
    func classifiesReservedRanges() throws {
        #expect(try #require(IPv4Address("10.0.0.1")).isPrivateUse)
        #expect(try #require(IPv4Address("172.16.0.1")).isPrivateUse)
        #expect(try #require(IPv4Address("172.31.255.254")).isPrivateUse)
        #expect(try #require(IPv4Address("192.168.1.1")).isPrivateUse)

        // 172.15 and 172.32 sit just outside 172.16.0.0/12 — the boundary most often got
        // wrong by implementations that check only the first octet.
        #expect(!(try #require(IPv4Address("172.15.0.1")).isPrivateUse))
        #expect(!(try #require(IPv4Address("172.32.0.1")).isPrivateUse))
        #expect(!(try #require(IPv4Address("8.8.8.8")).isPrivateUse))

        #expect(try #require(IPv4Address("127.0.0.1")).isLoopback)
        #expect(try #require(IPv4Address("169.254.1.1")).isLinkLocal)
        #expect(try #require(IPv4Address("224.0.0.1")).isMulticast)
        #expect(try #require(IPv4Address("0.0.0.0")).isUnspecified)
        #expect(try #require(IPv4Address("255.255.255.255")).isLimitedBroadcast)
    }

    @Test("excludes unusable addresses from host assignment",
          arguments: ["0.0.0.0", "127.0.0.1", "169.254.1.1", "224.0.0.1",
                      "255.255.255.255", "240.0.0.1"])
    func excludesUnusableAddresses(text: String) throws {
        #expect(!(try #require(IPv4Address(text)).isAssignableHostAddress))
    }

    @Test("does not wrap when arithmetic leaves the address space")
    func doesNotWrapOnOverflow() throws {
        let top = try #require(IPv4Address("255.255.255.255"))
        // Wrapping to 0.0.0.0 would turn an off-by-one into a plausible-looking address.
        #expect(top.adding(1) == nil)
        #expect(try #require(IPv4Address("1.2.3.4")).adding(1)?.description == "1.2.3.5")
    }

    @Test("counts addresses in a range, and refuses an inverted one")
    func countsAddressRanges() throws {
        let start = try #require(IPv4Address("192.168.50.10"))
        let end = try #require(IPv4Address("192.168.50.200"))

        // Inclusive of both endpoints: 200 - 10 + 1.
        #expect(start.addressCount(through: end) == 191)
        #expect(start.addressCount(through: start) == 1)
        #expect(end.addressCount(through: start) == nil)
    }

    @Test("encodes as a string and validates on decode")
    func codableRoundTrip() throws {
        let original = try #require(IPv4Address("192.168.50.1"))
        let data = try JSONEncoder().encode(original)

        #expect(String(data: data, encoding: .utf8) == "\"192.168.50.1\"")
        #expect(try JSONDecoder().decode(IPv4Address.self, from: data) == original)
    }

    @Test("rejects an invalid address in a decoded document")
    func rejectsInvalidOnDecode() {
        // A hand-edited profile is untrusted input like any other, so decoding applies the
        // same rules as typing into the field.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(IPv4Address.self, from: Data("\"999.1.1.1\"".utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(IPv4Address.self, from: Data("\"010.1.1.1\"".utf8))
        }
    }
}
