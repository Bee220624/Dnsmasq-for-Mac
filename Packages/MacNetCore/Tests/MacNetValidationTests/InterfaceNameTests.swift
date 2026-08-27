import Testing
import MacNetValidation

@Suite("Interface name validation")
struct InterfaceNameTests {

    private func rejection(_ input: String) -> InterfaceName.Failure? {
        if case .failure(let failure) = InterfaceName.validate(input) { return failure }
        return nil
    }

    @Test("accepts real wired interface names",
          arguments: ["en0", "en7", "en12", "eth0", "ix0", "vmenet0"])
    func acceptsRealNames(input: String) {
        #expect(rejection(input) == nil)
    }

    @Test("rejects names that are not plain identifiers",
          arguments: ["", "7en", "EN7", "en 7", "en-7", "en_7", "en.7", "en/7",
                      "-en7", "en7!", "éth0", String(repeating: "e", count: 17)])
    func rejectsMalformedNames(input: String) {
        #expect(rejection(input) == .malformed || rejection(input) == .empty)
    }

    @Test("blocks interfaces that must never host a session",
          arguments: ["lo0", "awdl0", "llw0", "utun0", "utun12", "bridge0", "bridge100",
                      "gif0", "stf0", "p2p0", "ipsec0", "ppp0", "anpi0"])
    func blocksForbiddenInterfaces(input: String) {
        // Each is either not a real network or is one macOS manages itself. Matching on the
        // alphabetic prefix means unit numbers never have to be enumerated.
        #expect(rejection(input) == .blockedByPolicy)
    }

    @Test("blocks a family whose name contains a digit")
    func blocksFamilyWithDigitInName() {
        // p2p0 is real: macOS uses it for peer-to-peer Wi-Fi. Matching the blocklist against
        // the leading *letters* would reduce "p2p0" to "p" and let it through, which is
        // exactly the mistake this case exists to catch.
        #expect(rejection("p2p0") == .blockedByPolicy)
        #expect(rejection("p2p1") == .blockedByPolicy)
    }

    @Test("does not block a name that merely begins with a blocked family's letters",
          arguments: ["en0", "ix0", "logger", "bridgex", "gifted", "utunnel"])
    func doesNotOverBlock(input: String) {
        // A blocked family is its prefix plus a unit number. "logger" begins with "lo" but
        // "gger" is not a unit number, so it is a different interface and must stay usable —
        // an over-broad blocklist would silently make a real adapter unselectable.
        #expect(rejection(input) != .blockedByPolicy)
    }

    @Test("shape validation is not permission to use the interface")
    func shapeIsNotPermission() {
        // A name passing here says nothing about whether the interface exists, what type it
        // is, or whether it carries the default route. The specification requires the helper to
        // re-enumerate and decide those separately, so this must not be mistaken for a grant.
        #expect(rejection("en0") == nil)
    }
}
