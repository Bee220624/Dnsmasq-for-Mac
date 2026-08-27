import Foundation
import Testing
import MacNetModels
import MacNetXPC

/// Lifecycle coverage against fakes (ticket §24.2).
///
/// Every test here is a failure that cannot be produced on demand against a real machine, and
/// each one is a case where getting it wrong leaves an engineer's Mac in a state they did not
/// ask for. The assertion that appears most often is the same one: **nothing was left behind**.
@Suite("Session lifecycle")
struct SessionLifecycleTests {

    // MARK: - Fixture

    private struct Harness {
        let coordinator: SessionCoordinator
        let alias: FakeAliasManager
        let ports: FakePortProbe
        let process: FakeProcessController
        let verifier: FakeExecutableVerifier
        let commands: FakeCommandRunner
        let enumerator: FakeInterfaceEnumerator
        let runtimeFiles: RuntimeFileManager
        let journal: SessionJournalStore
        let root: String
    }

    private func makeHarness(
        interfaces: [NetworkInterfaceDescriptor] = [TestInterface.ethernet("en7")]
    ) -> Harness {
        let root = NSTemporaryDirectory() + "dnsmasqformac-session-\(UUID().uuidString)"
        // Tests that write a journal directly need the root to exist; `start` prepares it
        // itself, so this only serves the recovery cases that bypass it.
        try? FileManager.default.createDirectory(
            atPath: "\(root)/sessions", withIntermediateDirectories: true
        )
        let applier = RecordingOwnershipApplier()
        let runtimeFiles = RuntimeFileManager(root: root, ownershipApplier: applier)
        let journal = SessionJournalStore(fileManager: runtimeFiles)

        let alias = FakeAliasManager()
        let ports = FakePortProbe()
        let process = FakeProcessController()
        let verifier = FakeExecutableVerifier()
        let commands = FakeCommandRunner()
        let enumerator = FakeInterfaceEnumerator(interfaces)

        let coordinator = SessionCoordinator(
            runtimeFiles: runtimeFiles,
            journalStore: journal,
            fileLock: RuntimeFileLock(path: "\(root)/lock"),
            enumerator: enumerator,
            aliasManager: alias,
            portProbe: ports,
            processController: process,
            executableVerifier: verifier,
            commandRunner: commands,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        return Harness(
            coordinator: coordinator, alias: alias, ports: ports, process: process,
            verifier: verifier, commands: commands, enumerator: enumerator,
            runtimeFiles: runtimeFiles, journal: journal, root: root
        )
    }

    private func cleanUp(_ harness: Harness) {
        try? FileManager.default.removeItem(atPath: harness.root)
    }

    private func makeRequest(
        interface: String = "en7",
        dhcpEnabled: Bool = true,
        confirmed: Bool = true
    ) -> SessionStartRequest {
        var profile = NetworkProfile.makeDefault(now: Date(timeIntervalSince1970: 1_700_000_000))
        profile.dhcpConfiguration.enabled = dhcpEnabled
        // Local records only, so the request needs no system resolvers to be valid.
        profile.dnsConfiguration.upstreamMode = .localOnly

        let descriptor = TestInterface.ethernet(interface)
        return SessionStartRequest(draft: SessionDraft(
            profileSnapshot: profile,
            selectedInterface: descriptor,
            resolvedSystemDNSServers: [],
            safetyConfirmation: confirmed
        ))
    }

    // MARK: - Start: the happy path

    @Test("a successful start adds the alias, launches, and records a running session")
    func startSucceeds() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        let session = try await harness.coordinator.start(request: makeRequest())

        #expect(session.dnsmasqPID == harness.process.pidToReturn)
        #expect(session.aliasAddedByApp)
        #expect(harness.alias.addedAliases.count == 1)
        #expect(harness.process.launchCount == 1)

        let state = await harness.coordinator.runtimeStatus()
        guard case .running(let running) = state else {
            Issue.record("expected a running state, got \(state)")
            return
        }
        #expect(running.id == session.id)

        // The journal is what makes recovery possible after a crash; it must describe reality.
        let journal = try #require(harness.journal.read())
        #expect(journal.state == .running)
        #expect(journal.aliasAddedByApp)
        #expect(journal.dnsmasqPID == harness.process.pidToReturn)
    }

    @Test("dnsmasq is launched with a fixed argument list and the generated configuration")
    func launchUsesGeneratedConfiguration() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        _ = try await harness.coordinator.start(request: makeRequest())

        // Every user-chosen setting reached dnsmasq through the configuration file. Nothing the
        // user typed becomes an argument (ticket §9.9).
        let configurationPath = try #require(harness.process.lastConfigurationPath)
        #expect(configurationPath.hasSuffix("/dnsmasq.conf"))
        #expect(configurationPath.hasPrefix(harness.root))

        let written = try harness.runtimeFiles.readFile(at: configurationPath, maximumBytes: 1 << 20)
        #expect(written.contains("interface=en7"))
        #expect(written.contains("bind-interfaces"))
        #expect(written.contains("no-hosts"))
    }

    // MARK: - Start: refusals

    @Test("DHCP without the isolation confirmation is refused")
    func refusesUnconfirmedDHCP() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        // Ticket §5.3.5: the confirmation travels inside the request precisely so the helper
        // can refuse, rather than trusting the UI to have asked.
        let failure = await #expect(throws: ServiceFailure.self) {
            try await harness.coordinator.start(request: makeRequest(confirmed: false))
        }
        #expect(failure?.code == .invalidRequest)

        #expect(harness.alias.addedAliases.isEmpty)
        #expect(harness.process.launchCount == 0)
    }

    @Test("a DNS-only session does not require the DHCP confirmation")
    func dnsOnlyNeedsNoConfirmation() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        // The confirmation exists because DHCP can disrupt a network. DNS on a chosen
        // interface cannot, so requiring it would be friction with no safety value.
        _ = try await harness.coordinator.start(
            request: makeRequest(dhcpEnabled: false, confirmed: false)
        )
        #expect(harness.process.launchCount == 1)
    }

    @Test("Wi-Fi is refused even if the request claims it is Ethernet")
    func refusesWiFi() async throws {
        // The request carries a snapshot claiming Ethernet; the live enumeration says Wi-Fi.
        // Ticket §12.4: the helper re-enumerates and never trusts what it was sent.
        let harness = makeHarness(interfaces: [TestInterface.wifi("en0")])
        defer { cleanUp(harness) }

        let failure = await #expect(throws: ServiceFailure.self) {
            try await harness.coordinator.start(request: makeRequest(interface: "en0"))
        }
        #expect(failure?.code == .interfaceIsWiFi)
        #expect(harness.alias.addedAliases.isEmpty)
    }

    @Test("an interface that has been unplugged is refused")
    func refusesMissingInterface() async throws {
        let harness = makeHarness(interfaces: [])
        defer { cleanUp(harness) }

        let failure = await #expect(throws: ServiceFailure.self) {
            try await harness.coordinator.start(request: makeRequest())
        }
        #expect(failure?.code == .interfaceNotFound)
        #expect(harness.alias.addedAliases.isEmpty)
    }

    @Test("a second session is refused while one is running")
    func refusesSecondSession() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        _ = try await harness.coordinator.start(request: makeRequest())

        // Ticket §21.6. Two dnsmasq instances would fight over ports 53 and 67, and the
        // second's failure would be far more confusing than a refusal.
        await #expect(throws: ServiceFailure.self) {
            try await harness.coordinator.start(request: makeRequest())
        }
        #expect(harness.process.launchCount == 1)
    }

    // MARK: - Start: rollback

    @Test("a configuration that dnsmasq rejects rolls everything back")
    func rollsBackOnInvalidConfiguration() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        harness.commands.stub(
            when: { executable, arguments in
                executable == .bundledDnsmasq && arguments.contains("--test")
            },
            return: CommandResult(
                exitStatus: 1, standardOutput: "",
                standardError: "dnsmasq: bad option at line 3"
            )
        )

        let failure = await #expect(throws: ServiceFailure.self) {
            try await harness.coordinator.start(request: makeRequest())
        }
        #expect(failure?.code == .dnsmasqConfigInvalid)
        // The dnsmasq message is what makes this diagnosable.
        #expect(failure?.technicalDetails?.contains("bad option") == true)

        // The test runs before the alias is added, so nothing should have touched the machine.
        #expect(harness.alias.addedAliases.isEmpty)
        #expect(harness.process.launchCount == 0)
        #expect(harness.journal.read() == nil)
    }

    @Test("an alias that cannot be added rolls back without launching")
    func rollsBackOnAliasFailure() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        harness.alias.addFailure = ServiceFailure(
            code: .aliasConfigurationFailed,
            title: "Could Not Add IP Address",
            message: "macOS refused the change."
        )

        await #expect(throws: ServiceFailure.self) {
            try await harness.coordinator.start(request: makeRequest())
        }
        #expect(harness.process.launchCount == 0)
        #expect(harness.journal.read() == nil)
    }

    @Test("a port taken after the alias is added rolls the alias back out")
    func rollsBackAliasOnLatePortConflict() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        // The exact race ticket §15.1 step 12 exists to catch: free when preflight looked,
        // taken by the time the address is on the interface. Preflight is run first so it
        // consumes the "available" answer, exactly as it would in the real flow.
        harness.ports.sequence([.available, .inUse], for: .dhcpServer)

        let report = await harness.coordinator.preflight(request: makeRequest())
        #expect(!report.hasBlockingIssues, "preflight should see the port as free")

        let failure = await #expect(throws: ServiceFailure.self) {
            try await harness.coordinator.start(request: makeRequest())
        }
        #expect(failure?.code == .portInUse)

        // The alias was added, then removed. Leaving it behind would be the failure named in
        // ticket §15.2.
        #expect(harness.alias.addedAliases.count == 1)
        #expect(harness.alias.isBalanced, "the alias must not survive a rolled-back start")
        #expect(harness.process.launchCount == 0)
        #expect(harness.journal.read() == nil)
    }

    @Test("dnsmasq exiting immediately rolls back the alias and reports the log")
    func rollsBackWhenDnsmasqExitsImmediately() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        // Launch reports success, then the process is gone by the time readiness is checked.
        harness.process.livenessOverride = .notRunning

        let failure = await #expect(throws: ServiceFailure.self) {
            try await harness.coordinator.start(request: makeRequest())
        }
        #expect(failure?.code == .processStartFailed)

        #expect(harness.alias.isBalanced, "the alias must not survive a failed start")
        #expect(harness.process.terminateCount >= 1)
        #expect(harness.journal.read() == nil)

        let state = await harness.coordinator.runtimeStatus()
        #expect(state == .stopped)
    }

    @Test("a launch that cannot start at all rolls back")
    func rollsBackWhenLaunchFails() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        harness.process.launchFailure = ServiceFailure(
            code: .processStartFailed,
            title: "Could Not Start dnsmasq",
            message: "The engine could not be started."
        )

        await #expect(throws: ServiceFailure.self) {
            try await harness.coordinator.start(request: makeRequest())
        }
        #expect(harness.alias.isBalanced)
        #expect(harness.journal.read() == nil)
    }

    @Test("a failed engine verification stops the start before anything happens")
    func refusesUnverifiedEngine() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        harness.verifier.failure = ServiceFailure(
            code: .dnsmasqHashMismatch,
            title: "Engine Verification Failed",
            message: "The bundled engine is not the one we shipped."
        )

        let failure = await #expect(throws: ServiceFailure.self) {
            try await harness.coordinator.start(request: makeRequest())
        }
        #expect(failure?.code == .dnsmasqHashMismatch)
        #expect(harness.alias.addedAliases.isEmpty)
        #expect(harness.process.launchCount == 0)
    }

    // MARK: - Stop

    @Test("stopping terminates the process and removes the alias")
    func stopCleansUp() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        let session = try await harness.coordinator.start(request: makeRequest())
        try await harness.coordinator.stop(sessionID: session.id)

        #expect(harness.process.terminateCount == 1)
        #expect(harness.alias.isBalanced)
        #expect(harness.journal.read() == nil)
        #expect(await harness.coordinator.runtimeStatus() == .stopped)
    }

    @Test("a stop that cannot remove the alias reports it instead of claiming success")
    func stopReportsAliasCleanupFailure() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        let session = try await harness.coordinator.start(request: makeRequest())
        harness.alias.removeFailure = ServiceFailure(
            code: .cleanupFailed,
            title: "Could Not Remove IP Address",
            message: "192.168.50.1 is still configured on en7.",
            recoverySuggestion: "sudo ifconfig en7 inet 192.168.50.1 -alias"
        )

        // Ticket §13.2 forbids hiding this: the user's Mac is left holding an address, and
        // reporting success would mean they never find out.
        let failure = await #expect(throws: ServiceFailure.self) {
            try await harness.coordinator.stop(sessionID: session.id)
        }
        #expect(failure?.code == .cleanupFailed)
        #expect(failure?.recoverySuggestion?.contains("-alias") == true)

        // The journal survives so the next start knows there is something to clean up.
        let journal = try #require(harness.journal.read())
        #expect(journal.state == .cleanupRequired)
    }

    @Test("a stale PID does not prevent the alias from being removed")
    func stopRemovesAliasEvenWhenProcessIsStale() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        let session = try await harness.coordinator.start(request: makeRequest())

        // The PID has been recycled. Nothing may be signalled — but the address on the user's
        // interface is still ours to remove, and that is the part they would notice.
        harness.process.terminateFailure = ServiceFailure(
            code: .staleSession,
            title: "Session Is Stale",
            message: "That process ID now belongs to something else."
        )

        try await harness.coordinator.stop(sessionID: session.id)
        #expect(harness.alias.isBalanced, "a stale process must not strand the alias")
        #expect(await harness.coordinator.runtimeStatus() == .stopped)
    }

    @Test("stopping something that is not running is not an error")
    func stopWhenNotRunningIsHarmless() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        // The app may be retrying after a dropped connection. The desired end state has
        // already been reached, so this is success, not failure.
        try await harness.coordinator.stop(sessionID: UUID())
        #expect(await harness.coordinator.runtimeStatus() == .stopped)
    }

    // MARK: - Recovery

    @Test("with no journal there is nothing to recover")
    func recoveryWithNoJournal() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        let report = await harness.coordinator.recoverStaleState()
        #expect(report.outcome == .nothingToRecover)
    }

    @Test("a journal whose process is gone has its alias cleaned up")
    func recoveryCleansUpAfterDeadProcess() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        // Simulate the helper being killed mid-session: a journal describing an added alias
        // and a process that no longer exists (ticket §17.3 case C).
        let journal = SessionJournal(
            sessionID: UUID(),
            state: .running,
            interfaceBSDName: "en7",
            serverIPv4: IPv4Address(rawValue: 0xC0A8_3201),
            prefixLength: 24,
            aliasAddedByApp: true,
            interfaceWasUpBeforeStart: true,
            dnsmasqPID: 99_999,
            dnsmasqExecutableSHA256: String(repeating: "a", count: 64),
            configurationPath: "\(harness.root)/x/dnsmasq.conf",
            leasePath: "\(harness.root)/x/dnsmasq.leases",
            logPath: "\(harness.root)/x/dnsmasq.log",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try harness.journal.write(journal)
        harness.process.livenessOverride = .notRunning

        let report = await harness.coordinator.recoverStaleState()

        #expect(report.outcome == .cleanedUpAfterDeadProcess)
        #expect(harness.alias.removedAliases.count == 1)
        #expect(harness.journal.read() == nil)
    }

    @Test("a recycled PID is never signalled, and is reported for attention")
    func recoveryRefusesToSignalRecycledPID() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        let journal = SessionJournal(
            sessionID: UUID(),
            state: .running,
            interfaceBSDName: "en7",
            serverIPv4: IPv4Address(rawValue: 0xC0A8_3201),
            prefixLength: 24,
            aliasAddedByApp: true,
            interfaceWasUpBeforeStart: true,
            dnsmasqPID: 4242,
            dnsmasqExecutableSHA256: String(repeating: "a", count: 64),
            configurationPath: "", leasePath: "", logPath: "",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try harness.journal.write(journal)
        harness.process.livenessOverride = .identityMismatch(actualPath: "/usr/bin/vim")

        let report = await harness.coordinator.recoverStaleState()

        // Ticket §17.3 case D. Signalling here would kill whatever the user is running.
        #expect(report.outcome == .staleSessionRequiresAttention)
        #expect(harness.process.terminateCount == 0)
        #expect(!report.warnings.isEmpty)
        // The alias is still ours and is still removed — that part is unambiguous.
        #expect(harness.alias.removedAliases.count == 1)
    }

    @Test("recovery never removes an alias the app did not add")
    func recoveryLeavesForeignAddressesAlone() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        // The user configured this address themselves; the session merely used it.
        let journal = SessionJournal(
            sessionID: UUID(),
            state: .running,
            interfaceBSDName: "en7",
            serverIPv4: IPv4Address(rawValue: 0xC0A8_3201),
            prefixLength: 24,
            aliasAddedByApp: false,
            interfaceWasUpBeforeStart: true,
            dnsmasqPID: 99_999,
            dnsmasqExecutableSHA256: String(repeating: "a", count: 64),
            configurationPath: "", leasePath: "", logPath: "",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try harness.journal.write(journal)
        harness.process.livenessOverride = .notRunning

        _ = await harness.coordinator.recoverStaleState()

        // Ticket §13.2. Removing an address the user set would be a far worse bug than
        // leaving one of ours behind.
        #expect(harness.alias.removedAliases.isEmpty)
    }

    @Test("a start after an unclean shutdown cleans up before proceeding")
    func startRecoversBeforeStarting() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        let stale = SessionJournal(
            sessionID: UUID(),
            state: .aliasAdded,
            interfaceBSDName: "en7",
            serverIPv4: IPv4Address(rawValue: 0xC0A8_3201),
            prefixLength: 24,
            aliasAddedByApp: true,
            interfaceWasUpBeforeStart: true,
            dnsmasqPID: nil,
            dnsmasqExecutableSHA256: String(repeating: "a", count: 64),
            configurationPath: "", leasePath: "", logPath: "",
            startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_690_000_000)
        )
        try harness.journal.write(stale)
        // No liveness override: the stale journal names a PID this fake never launched, so it
        // reports notRunning, while the process the new start launches reports running — which
        // is exactly the sequence a real machine produces.
        let session = try await harness.coordinator.start(request: makeRequest())

        // The orphaned alias from the previous run is removed before the new one is added.
        // Otherwise it would stay on the interface forever.
        #expect(harness.alias.removedAliases.count >= 1)
        #expect(session.aliasAddedByApp)
        #expect(await harness.coordinator.runtimeStatus() != .stopped)
    }
}
