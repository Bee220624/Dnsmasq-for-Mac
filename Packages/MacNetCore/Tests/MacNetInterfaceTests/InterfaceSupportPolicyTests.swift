import Testing
import MacNetModels
import MacNetValidation
@testable import MacNetInterfaces

/// The policy that decides where DHCP may run. Getting this wrong is how the product takes
/// down someone's office network, so every refusal in the specification is asserted individually.
@Suite("Interface support policy")
struct InterfaceSupportPolicyTests {

    @Test("a plain wired Ethernet interface that is not the default route is permitted")
    func permitsWiredEthernet() {
        #expect(InterfaceSupportPolicy.rejection(
            bsdName: "en7", kind: .ethernet, isDefaultRoute: false
        ) == nil)
    }

    @Test("Wi-Fi is refused, whatever it is called")
    func refusesWiFi() {
        // Refused on the SystemConfiguration type, never on the name: en0 is Wi-Fi on a laptop
        // and Ethernet on a Mac mini.
        #expect(InterfaceSupportPolicy.rejection(
            bsdName: "en0", kind: .wifi, isDefaultRoute: false
        ) == .isWiFi)
        #expect(InterfaceSupportPolicy.rejection(
            bsdName: "en1", kind: .wifi, isDefaultRoute: false
        ) == .isWiFi)
    }

    @Test("the default-route interface is refused even when it is wired Ethernet")
    func refusesDefaultRoute() {
        // Serving DHCP here would disrupt the network this Mac is currently using.
        #expect(InterfaceSupportPolicy.rejection(
            bsdName: "en7", kind: .ethernet, isDefaultRoute: true
        ) == .isDefaultRoute)
    }

    @Test("Wi-Fi is reported as Wi-Fi even when it also carries the default route")
    func reportsMostEmphaticReason() {
        // Both rules apply. The message the user sees should be the one that explains why this
        // will never work, not the one that sounds like a temporary condition.
        #expect(InterfaceSupportPolicy.rejection(
            bsdName: "en0", kind: .wifi, isDefaultRoute: true
        ) == .isWiFi)
    }

    @Test("non-Ethernet kinds are refused",
          arguments: [NetworkInterfaceKind.loopback, .bridge, .vpn, .virtual, .unknown])
    func refusesOtherKinds(kind: NetworkInterfaceKind) {
        #expect(InterfaceSupportPolicy.rejection(
            bsdName: "en7", kind: kind, isDefaultRoute: false
        ) == .kindNotPermitted(kind))
    }

    @Test("interfaces macOS manages itself are refused by name",
          arguments: ["lo0", "awdl0", "utun3", "bridge0", "p2p0", "llw0", "gif0", "stf0"])
    func refusesManagedInterfaces(bsdName: String) {
        let rejection = InterfaceSupportPolicy.rejection(
            bsdName: bsdName, kind: .ethernet, isDefaultRoute: false
        )
        // Claimed to be Ethernet on purpose: the name rule must hold even if something else
        // misreports the kind.
        #expect(rejection == .nameNotPermitted(.blockedByPolicy))
    }

    @Test("every rejection explains itself in terms the user can act on")
    func rejectionsHaveUsefulMessages() {
        let rejections: [InterfaceSupportPolicy.Rejection] = [
            .isWiFi, .isDefaultRoute, .kindNotPermitted(.vpn),
            .nameNotPermitted(.blockedByPolicy), .nameNotPermitted(.malformed),
        ]
        for rejection in rejections {
            #expect(!rejection.message.isEmpty)
            // A message that only names the rule ("kind not permitted") tells the user
            // nothing about what to do instead.
            #expect(rejection.message.count > 30, "\(rejection) has an unhelpful message")
        }
    }

    // MARK: - Ordering

    private func descriptor(
        _ bsdName: String,
        kind: NetworkInterfaceKind = .ethernet,
        linkActive: Bool = true,
        defaultRoute: Bool = false
    ) -> NetworkInterfaceDescriptor {
        let rejection = InterfaceSupportPolicy.rejection(
            bsdName: bsdName, kind: kind, isDefaultRoute: defaultRoute
        )
        return NetworkInterfaceDescriptor(
            bsdName: bsdName, displayName: bsdName, hardwarePortName: nil, kind: kind,
            macAddress: nil, ipv4Addresses: [], isUp: true, isRunning: linkActive,
            isLinkActive: linkActive, isDefaultRoute: defaultRoute,
            isSupported: rejection == nil, unsupportedReason: rejection?.message
        )
    }

    @Test("connected Ethernet sorts first, refused interfaces last")
    func sortsForSelection() {
        let sorted = InterfaceSupportPolicy.sorted([
            descriptor("en0", kind: .wifi),
            descriptor("lo0", kind: .loopback),
            descriptor("en5", linkActive: false),
            descriptor("en7", linkActive: true),
        ])

        // The adapter that was just plugged in should be at the top; everything unusable stays
        // visible but out of the way.
        #expect(sorted.map(\.bsdName) == ["en7", "en5", "en0", "lo0"])
    }

    @Test("ordering is stable for interfaces of equal rank")
    func orderingIsStable() {
        // Without a tiebreak the list would reshuffle on every refresh as the system reports
        // interfaces in a different order.
        let first = InterfaceSupportPolicy.sorted([
            descriptor("en9"), descriptor("en3"), descriptor("en11"),
        ])
        let second = InterfaceSupportPolicy.sorted([
            descriptor("en11"), descriptor("en9"), descriptor("en3"),
        ])
        #expect(first.map(\.bsdName) == second.map(\.bsdName))
        // Natural ordering, so en3 precedes en11.
        #expect(first.map(\.bsdName) == ["en3", "en9", "en11"])
    }

    // MARK: - Default selection

    @Test("prefers the interface used last time")
    func prefersRemembered() {
        let choice = InterfaceSupportPolicy.defaultSelection(
            from: [descriptor("en7"), descriptor("en5")], preferring: "en5"
        )
        #expect(choice?.bsdName == "en5")
    }

    @Test("falls back to a connected Ethernet when the remembered one is gone")
    func fallsBackToConnected() {
        // The usual case for a USB adapter: its BSD name changed between sessions.
        let choice = InterfaceSupportPolicy.defaultSelection(
            from: [descriptor("en5", linkActive: false), descriptor("en7", linkActive: true)],
            preferring: "en99"
        )
        #expect(choice?.bsdName == "en7")
    }

    @Test("selects a disconnected Ethernet when nothing has a link")
    func selectsDisconnectedEthernet() {
        // The device may simply not be powered on yet, so Link Down is not disqualifying.
        let choice = InterfaceSupportPolicy.defaultSelection(
            from: [descriptor("en5", linkActive: false)], preferring: nil
        )
        #expect(choice?.bsdName == "en5")
    }

    @Test("never auto-selects Wi-Fi, even as the only interface present")
    func neverAutoSelectsWiFi() {
        // The specification Preselecting Wi-Fi would put the user one confirmation away from
        // running DHCP on whatever network they are actually on.
        #expect(InterfaceSupportPolicy.defaultSelection(
            from: [descriptor("en0", kind: .wifi)], preferring: nil
        ) == nil)

        // Not even when it is what they used last — the remembered name is only honoured for
        // an interface that is still permitted.
        #expect(InterfaceSupportPolicy.defaultSelection(
            from: [descriptor("en0", kind: .wifi)], preferring: "en0"
        ) == nil)
    }

    @Test("never auto-selects the default-route interface")
    func neverAutoSelectsDefaultRoute() {
        #expect(InterfaceSupportPolicy.defaultSelection(
            from: [descriptor("en7", defaultRoute: true)], preferring: "en7"
        ) == nil)
    }

    @Test("selects nothing rather than guessing when no interface qualifies")
    func selectsNothingWhenNothingQualifies() {
        #expect(InterfaceSupportPolicy.defaultSelection(from: [], preferring: nil) == nil)
        #expect(InterfaceSupportPolicy.defaultSelection(
            from: [descriptor("lo0", kind: .loopback), descriptor("en0", kind: .wifi)],
            preferring: nil
        ) == nil)
    }
}
