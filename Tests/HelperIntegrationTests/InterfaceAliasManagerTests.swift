import Foundation
import Testing
import MacNetModels

/// Coverage for temporary IPv4 alias management.
///
/// This is the component that changes the user's machine. Every test here is about a case
/// where getting it wrong leaves a Mac holding an address it should not have, or strips one it
/// should have kept.
@Suite("Interface alias manager")
struct InterfaceAliasManagerTests {

    private let serverAddress = IPv4Address(rawValue: 0xC0A8_3201)   // 192.168.50.1

    private func makeManager(
        interfaces: [NetworkInterfaceDescriptor]
    ) -> (InterfaceAliasManager, FakeCommandRunner, FakeInterfaceEnumerator) {
        let runner = FakeCommandRunner()
        let enumerator = FakeInterfaceEnumerator(interfaces)
        return (
            InterfaceAliasManager(commandRunner: runner, enumerator: enumerator),
            runner,
            enumerator
        )
    }

    // MARK: - Adding

    @Test("adds an alias with an argument array, never a command string")
    func addsAliasWithArgumentArray() async throws {
        let before = TestInterface.ethernet("en7")
        let after = TestInterface.ethernet(
            "en7", addresses: [("192.168.50.1", "255.255.255.0")]
        )
        let (manager, runner, enumerator) = makeManager(interfaces: [before])
        // The address only appears once ifconfig has run.
        enumerator.change(to: [after], afterCall: 1)

        try await manager.addAlias(interface: "en7", address: serverAddress, prefixLength: 24)

        // The specification: every value is its own array element. If this were ever assembled into
        // a string, a validated-but-hostile value could become a second command.
        #expect(runner.invocations == [
            FakeCommandRunner.Invocation(
                executable: .ifconfig,
                arguments: ["en7", "inet", "192.168.50.1", "netmask", "255.255.255.0", "alias"]
            )
        ])
    }

    @Test("does not add an alias that is already present")
    func skipsExistingAlias() async throws {
        let existing = TestInterface.ethernet(
            "en7", addresses: [("192.168.50.1", "255.255.255.0")]
        )
        let (manager, runner, _) = makeManager(interfaces: [existing])

        try await manager.addAlias(interface: "en7", address: serverAddress, prefixLength: 24)

        // The specification This matters for what happens *later*: an alias we did not add is one
        // we must not remove on stop, and re-adding it would blur that distinction.
        #expect(runner.invocations.isEmpty)
    }

    @Test("refuses when the address exists with a different prefix")
    func refusesConflictingPrefix() async throws {
        // Same address, /16 rather than /24. Silently proceeding would leave the interface
        // configured differently from what the session believes.
        let existing = TestInterface.ethernet(
            "en7", addresses: [("192.168.50.1", "255.255.0.0")]
        )
        let (manager, runner, _) = makeManager(interfaces: [existing])

        let failure = await #expect(throws: ServiceFailure.self) {
            try await manager.addAlias(
                interface: "en7", address: serverAddress, prefixLength: 24
            )
        }
        #expect(failure?.code == .aliasConfigurationFailed)
        #expect(runner.invocations.isEmpty)
    }

    @Test("fails when ifconfig reports success but the address never appears")
    func failsWhenAddressDoesNotAppear() async throws {
        // ifconfig exits 0 and the address is still not there. The specification requires
        // confirming through getifaddrs rather than trusting an exit status.
        let unchanged = TestInterface.ethernet("en7")
        let (manager, _, _) = makeManager(interfaces: [unchanged])

        let failure = await #expect(throws: ServiceFailure.self) {
            try await manager.addAlias(
                interface: "en7", address: serverAddress, prefixLength: 24
            )
        }
        #expect(failure?.code == .aliasConfigurationFailed)
    }

    @Test("reports a non-zero ifconfig exit with its stderr")
    func reportsIfconfigFailure() async throws {
        let (manager, runner, _) = makeManager(interfaces: [TestInterface.ethernet("en7")])
        runner.stub(when: { executable, _ in executable == .ifconfig },
                    return: CommandResult(
                        exitStatus: 1,
                        standardOutput: "",
                        standardError: "ifconfig: ioctl (SIOCAIFADDR): File exists"
                    ))

        let failure = await #expect(throws: ServiceFailure.self) {
            try await manager.addAlias(
                interface: "en7", address: serverAddress, prefixLength: 24
            )
        }
        // The stderr is what a user or a support engineer actually needs.
        #expect(failure?.technicalDetails?.contains("SIOCAIFADDR") == true)
    }

    @Test("refuses an interface that is missing")
    func refusesMissingInterface() async throws {
        let (manager, runner, _) = makeManager(interfaces: [])

        let failure = await #expect(throws: ServiceFailure.self) {
            try await manager.addAlias(
                interface: "en7", address: serverAddress, prefixLength: 24
            )
        }
        #expect(failure?.code == .interfaceNotFound)
        #expect(runner.invocations.isEmpty)
    }

    @Test("re-validates the interface name it was handed",
          arguments: ["lo0", "utun0", "awdl0", "p2p0", "en7;rm -rf /", "EN7", "../etc"])
    func revalidatesInterfaceName(name: String) async throws {
        // The app validated this too, and that is irrelevant: the specification makes helper-side
        // validation the security boundary, and this value is about to become an argument to a
        // root-privileged program.
        let (manager, runner, _) = makeManager(interfaces: [TestInterface.ethernet("en7")])

        await #expect(throws: ServiceFailure.self) {
            try await manager.addAlias(
                interface: name, address: serverAddress, prefixLength: 24
            )
        }
        #expect(runner.invocations.isEmpty, "\(name) must never reach ifconfig")
    }

    @Test("refuses a prefix length outside the permitted range", arguments: [0, 7, 31, 32])
    func refusesBadPrefix(prefix: Int) async throws {
        let (manager, runner, _) = makeManager(interfaces: [TestInterface.ethernet("en7")])

        await #expect(throws: ServiceFailure.self) {
            try await manager.addAlias(
                interface: "en7", address: serverAddress, prefixLength: prefix
            )
        }
        #expect(runner.invocations.isEmpty)
    }

    // MARK: - Removing

    @Test("removes an alias with the documented argument form")
    func removesAlias() async throws {
        let present = TestInterface.ethernet(
            "en7", addresses: [("192.168.50.1", "255.255.255.0")]
        )
        let absent = TestInterface.ethernet("en7")
        let (manager, runner, enumerator) = makeManager(interfaces: [present])
        enumerator.change(to: [absent], afterCall: 1)

        try await manager.removeAlias(interface: "en7", address: serverAddress)

        #expect(runner.invocations == [
            FakeCommandRunner.Invocation(
                executable: .ifconfig,
                arguments: ["en7", "inet", "192.168.50.1", "-alias"]
            )
        ])
    }

    @Test("a vanished interface is not a failure")
    func vanishedInterfaceIsNotAFailure() async throws {
        // The specification: unplugging the adapter takes the alias with it. Treating this as an
        // error would leave the session stuck in cleanup-failed for something already resolved.
        let (manager, runner, _) = makeManager(interfaces: [])

        try await manager.removeAlias(interface: "en7", address: serverAddress)
        #expect(runner.invocations.isEmpty)
    }

    @Test("an address that is already gone is not a failure")
    func absentAddressIsNotAFailure() async throws {
        let (manager, runner, _) = makeManager(interfaces: [TestInterface.ethernet("en7")])

        try await manager.removeAlias(interface: "en7", address: serverAddress)
        #expect(runner.invocations.isEmpty)
    }

    @Test("a removal that does not take effect is reported with a manual recovery command")
    func reportsRemovalThatDidNotTakeEffect() async throws {
        // ifconfig succeeds, the address stays. The specification forbids hiding this: the user is
        // left with an address on their Mac and must be told how to remove it.
        let stubborn = TestInterface.ethernet(
            "en7", addresses: [("192.168.50.1", "255.255.255.0")]
        )
        let (manager, _, _) = makeManager(interfaces: [stubborn])

        let failure = await #expect(throws: ServiceFailure.self) {
            try await manager.removeAlias(interface: "en7", address: serverAddress)
        }
        #expect(failure?.code == .cleanupFailed)

        let suggestion = try #require(failure?.recoverySuggestion)
        // The exact interface and address, in a command the user can run.
        #expect(suggestion.contains("en7"))
        #expect(suggestion.contains("192.168.50.1"))
        #expect(suggestion.contains("-alias"))
    }

    // MARK: - Link state

    @Test("brings an interface up and back down")
    func setsInterfaceState() async throws {
        let (manager, runner, _) = makeManager(interfaces: [TestInterface.ethernet("en7")])

        try await manager.setInterfaceUp("en7", up: true)
        try await manager.setInterfaceUp("en7", up: false)

        #expect(runner.invocations.map(\.arguments) == [["en7", "up"], ["en7", "down"]])
    }
}
