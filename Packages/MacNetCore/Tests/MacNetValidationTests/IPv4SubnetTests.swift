import Testing
import MacNetModels

@Suite("IPv4 subnet arithmetic")
struct IPv4SubnetTests {

    // Nested `#require` calls expand recursively, so each unwrap gets its own statement.
    private func address(_ text: String) throws -> IPv4Address {
        try #require(IPv4Address(text))
    }

    private func subnet(_ text: String, _ prefix: Int) throws -> IPv4Subnet {
        let parsed = try address(text)
        return try #require(IPv4Subnet(containing: parsed, prefixLength: prefix))
    }

    @Test("derives netmask, network, and broadcast for a /24")
    func computesSlash24() throws {
        let net = try subnet("192.168.50.1", 24)

        #expect(net.netmask.description == "255.255.255.0")
        #expect(net.networkAddress.description == "192.168.50.0")
        #expect(net.broadcastAddress.description == "192.168.50.255")
        #expect(net.firstHostAddress.description == "192.168.50.1")
        #expect(net.lastHostAddress.description == "192.168.50.254")
        #expect(net.usableHostCount == 254)
    }

    @Test("derives a /30, the smallest subnet allowed")
    func computesSlash30() throws {
        let net = try subnet("192.168.50.5", 30)

        #expect(net.netmask.description == "255.255.255.252")
        #expect(net.networkAddress.description == "192.168.50.4")
        #expect(net.broadcastAddress.description == "192.168.50.7")
        // Two usable addresses: .5 and .6.
        #expect(net.usableHostCount == 2)
    }

    @Test("derives a /8 without overflowing the host count")
    func computesSlash8() throws {
        let net = try subnet("10.1.2.3", 8)

        #expect(net.netmask.description == "255.0.0.0")
        #expect(net.networkAddress.description == "10.0.0.0")
        #expect(net.broadcastAddress.description == "10.255.255.255")
        // 2^24 - 2. This exceeds Int32, which is why the count is UInt32.
        #expect(net.usableHostCount == 16_777_214)
    }

    @Test("refuses prefix lengths outside /8…/30", arguments: [0, 1, 7, 31, 32, 33, -1, 64])
    func refusesDisallowedPrefixLengths(prefix: Int) throws {
        let address = try address("192.168.50.1")
        // /31 and /32 are valid CIDR but leave no room for a server plus a pool, and a /0
        // would make the mask shift undefined. Refusing at construction means nothing
        // downstream has to re-check.
        #expect(IPv4Subnet(containing: address, prefixLength: prefix) == nil)
    }

    @Test("accepts every prefix length in range", arguments: Array(8...30))
    func acceptsAllowedPrefixLengths(prefix: Int) throws {
        let address = try address("10.0.0.1")
        #expect(IPv4Subnet(containing: address, prefixLength: prefix) != nil)
    }

    @Test("membership follows the mask, not the leading octets")
    func membershipFollowsMask() throws {
        let net = try subnet("192.168.50.1", 24)

        #expect(net.contains(try address("192.168.50.0")))
        #expect(net.contains(try address("192.168.50.255")))
        #expect(!net.contains(try address("192.168.51.0")))
        #expect(!net.contains(try address("192.168.49.255")))
    }

    @Test("network and broadcast addresses are not usable by hosts")
    func excludesNetworkAndBroadcast() throws {
        let net = try subnet("192.168.50.1", 24)

        #expect(!net.isUsableHostAddress(try address("192.168.50.0")))
        #expect(!net.isUsableHostAddress(try address("192.168.50.255")))
        #expect(net.isUsableHostAddress(try address("192.168.50.1")))
        #expect(net.isUsableHostAddress(try address("192.168.50.254")))
    }

    @Test("flags unusually wide subnets without rejecting them")
    func flagsWideSubnets() throws {
        // Allowed, but worth a warning: a /12 lab network is almost always a mistyped prefix.
        #expect(try subnet("10.0.0.1", 8).isUnusuallyWide)
        #expect(try subnet("10.0.0.1", 15).isUnusuallyWide)
        #expect(!(try subnet("10.0.0.1", 16).isUnusuallyWide))
        #expect(!(try subnet("192.168.50.1", 24).isUnusuallyWide))
    }

    @Test("reports a non-contiguous netmask as having no prefix length")
    func rejectsNonContiguousMask() throws {
        let entry = InterfaceIPv4Address(
            address: try address("192.168.50.1"),
            netmask: try address("255.0.255.0")
        )
        // Configurable, meaningless, and better surfaced as "unknown" than as a made-up number.
        #expect(entry.prefixLength == nil)

        let normal = InterfaceIPv4Address(
            address: try address("192.168.50.1"),
            netmask: try address("255.255.255.0")
        )
        #expect(normal.prefixLength == 24)
    }
}
