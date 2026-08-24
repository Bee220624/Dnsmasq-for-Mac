import Testing
import MacNetModels
@testable import MacNetInterfaces

/// Runs the real enumerator against the machine the tests are on.
///
/// These assert invariants rather than specific interfaces, because the hardware differs
/// between machines. What they prove is that the three data sources are being combined
/// correctly — which cannot be established from fixtures, since fixtures would encode
/// whatever the author believed `getifaddrs` returns.
@Suite("System interface enumeration")
struct SystemInterfaceEnumeratorTests {

    private let enumerator = SystemInterfaceEnumerator()

    @Test("finds interfaces on a real machine")
    func findsInterfaces() {
        let interfaces = enumerator.enumerateInterfaces()
        // Every Mac has at least loopback. Zero results means the enumeration itself broke.
        #expect(!interfaces.isEmpty)
    }

    @Test("always reports loopback, and always refuses it")
    func loopbackIsPresentAndRefused() throws {
        let interfaces = enumerator.enumerateInterfaces()
        let loopback = try #require(interfaces.first { $0.bsdName == "lo0" })

        #expect(!loopback.isSupported)
        #expect(loopback.unsupportedReason != nil)
    }

    @Test("no interface is both refused and missing a reason")
    func refusalsAlwaysExplained() {
        // A greyed-out row with no explanation is worse than not listing it: the user sees
        // their adapter and cannot tell why they may not choose it.
        for interface in enumerator.enumerateInterfaces() {
            if interface.isSupported {
                #expect(interface.unsupportedReason == nil, "\(interface.bsdName)")
            } else {
                #expect(interface.unsupportedReason != nil, "\(interface.bsdName)")
            }
        }
    }

    @Test("no Wi-Fi interface is ever reported as supported")
    func wifiIsNeverSupported() {
        for interface in enumerator.enumerateInterfaces() where interface.kind == .wifi {
            #expect(!interface.isSupported, "\(interface.bsdName) is Wi-Fi but was permitted")
        }
    }

    @Test("no default-route interface is ever reported as supported")
    func defaultRouteIsNeverSupported() {
        for interface in enumerator.enumerateInterfaces() where interface.isDefaultRoute {
            #expect(
                !interface.isSupported,
                "\(interface.bsdName) carries the default route but was permitted"
            )
        }
    }

    @Test("at most one interface carries the default route")
    func atMostOneDefaultRoute() {
        // Two would mean the dynamic store was misread, and the "is this my internet
        // connection" check would be unreliable.
        let count = enumerator.enumerateInterfaces().count(where: \.isDefaultRoute)
        #expect(count <= 1)
    }

    @Test("hardware addresses are well formed where present")
    func macAddressesAreWellFormed() {
        for interface in enumerator.enumerateInterfaces() {
            guard let mac = interface.macAddress else { continue }

            let octets = mac.split(separator: ":")
            #expect(octets.count == 6, "\(interface.bsdName) reported MAC \(mac)")
            for octet in octets {
                #expect(octet.count == 2, "\(interface.bsdName) reported MAC \(mac)")
                #expect(UInt8(octet, radix: 16) != nil, "\(interface.bsdName) reported MAC \(mac)")
            }
            // Lowercase is the normalized form used everywhere in the product.
            #expect(mac == mac.lowercased())
        }
    }

    @Test("loopback reports 127.0.0.1")
    func loopbackAddressIsCorrect() throws {
        // The one address that is the same on every Mac, so it is the one thing that can
        // actually be asserted about the AF_INET parsing.
        let interfaces = enumerator.enumerateInterfaces()
        let loopback = try #require(interfaces.first { $0.bsdName == "lo0" })

        let addresses = loopback.ipv4Addresses.map(\.address.description)
        #expect(addresses.contains("127.0.0.1"), "lo0 reported \(addresses)")
    }

    @Test("netmasks parse to sensible prefix lengths")
    func netmasksAreContiguous() {
        for interface in enumerator.enumerateInterfaces() {
            for entry in interface.ipv4Addresses {
                guard let prefix = entry.prefixLength else { continue }
                #expect((0...32).contains(prefix), "\(interface.bsdName): /\(prefix)")
            }
        }
    }

    @Test("enumeration is stable across consecutive calls")
    func enumerationIsStable() {
        // Not a determinism guarantee about the machine — an adapter really can be unplugged
        // mid-test — but the set of names should not churn on its own, and the ordering must
        // not depend on dictionary iteration order.
        let first = enumerator.enumerateInterfaces().map(\.bsdName)
        let second = enumerator.enumerateInterfaces().map(\.bsdName)
        #expect(first == second)
    }

    @Test("reports what this machine actually has", .tags(.diagnostic))
    func reportsMachineInventory() {
        // Not an assertion. Printing the inventory is what makes a failure elsewhere in this
        // suite diagnosable on a machine the author cannot see.
        for interface in enumerator.enumerateInterfaces() {
            let status = interface.isSupported ? "usable" : "refused"
            let addresses = interface.ipv4Addresses
                .map { entry in
                    entry.prefixLength.map { "\(entry.address)/\($0)" } ?? "\(entry.address)"
                }
                .joined(separator: ", ")

            Comment.record(
                """
                \(interface.bsdName) [\(interface.kind.rawValue)] \(status)
                  name: \(interface.displayName)
                  mac: \(interface.macAddress ?? "—")  ipv4: \(addresses.isEmpty ? "—" : addresses)
                  up: \(interface.isUp)  running: \(interface.isRunning) \
                link: \(interface.isLinkActive)  default-route: \(interface.isDefaultRoute)
                  \(interface.unsupportedReason ?? "")
                """
            )
        }
    }
}

extension Tag {
    @Tag static var diagnostic: Self
}

/// Emits a line into the test output without asserting anything.
private enum Comment {
    static func record(_ text: String) {
        print(text)
    }
}
