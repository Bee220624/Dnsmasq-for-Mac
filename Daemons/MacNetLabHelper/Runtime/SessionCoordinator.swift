import Foundation
import MacNetDnsmasq
import MacNetInterfaces
import MacNetModels
import MacNetValidation
import MacNetXPC
import OSLog

/// Owns the session lifecycle: preflight, start, stop, and recovery (ticket §15–§17).
///
/// ## Why an actor
///
/// Start is a transaction with real side effects on the user's machine — an IP alias, a running
/// process, files on disk. Two overlapping starts would interleave those effects and leave a
/// state nothing knows how to undo. The actor serialises within this process; a file lock
/// covers the case of a second helper instance.
///
/// ## The rule that shapes everything here
///
/// Every side effect is journalled *before* it is reported as done, and every failure unwinds
/// in reverse order. The failure modes this exists to prevent are named in ticket §15.2:
/// dnsmasq failing to start but the alias staying behind; the app showing Stopped while the
/// helper still runs dnsmasq; a journal pointing at a process that no longer exists; and not
/// being able to tell which step failed.
actor SessionCoordinator {

    // MARK: - Dependencies

    private let runtimeFiles: RuntimeFileManager
    private let journalStore: SessionJournalStore
    private let fileLock: RuntimeFileLock
    private let enumerator: any InterfaceEnumerating
    private let aliasManager: any InterfaceAliasManaging
    private let portProbe: any PortProbing
    private let processController: any ProcessControlling
    private let executableVerifier: any ExecutableVerifying
    private let commandRunner: any CommandRunning
    private let generator = DnsmasqConfigurationGenerator()

    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "session")

    /// Injected so tests can drive time rather than wait for it.
    private let clock: @Sendable () -> Date

    // MARK: - State

    private var state: RuntimeState = .stopped

    /// Notified when a session ends without being asked to (ticket §17.4).
    private var unexpectedExitHandler: (@Sendable (UnexpectedExitReport) -> Void)?

    private var exitWatcher: Task<Void, Never>?
    private var leaseWatcher: LeaseFileWatcher?

    init(
        runtimeFiles: RuntimeFileManager,
        journalStore: SessionJournalStore,
        fileLock: RuntimeFileLock,
        enumerator: any InterfaceEnumerating,
        aliasManager: any InterfaceAliasManaging,
        portProbe: any PortProbing,
        processController: any ProcessControlling,
        executableVerifier: any ExecutableVerifying,
        commandRunner: any CommandRunning,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runtimeFiles = runtimeFiles
        self.journalStore = journalStore
        self.fileLock = fileLock
        self.enumerator = enumerator
        self.aliasManager = aliasManager
        self.portProbe = portProbe
        self.processController = processController
        self.executableVerifier = executableVerifier
        self.commandRunner = commandRunner
        self.clock = clock
    }

    func setUnexpectedExitHandler(_ handler: @escaping @Sendable (UnexpectedExitReport) -> Void) {
        unexpectedExitHandler = handler
    }

    // MARK: - Status

    func runtimeStatus() -> RuntimeState { state }

    private var activeSession: ActiveSession? {
        if case .running(let session) = state { return session }
        return nil
    }

    // MARK: - Preflight

    func preflight(request: SessionStartRequest) async -> PreflightReport {
        state = .preflighting
        defer { state = activeSession.map(RuntimeState.running) ?? .stopped }

        let runner = PreflightRunner(
            enumerator: enumerator,
            portProbe: portProbe,
            executableVerifier: executableVerifier,
            commandRunner: commandRunner,
            fileManager: runtimeFiles
        )
        return await runner.run(
            request: request, existingSession: activeSession, now: clock()
        )
    }

    // MARK: - Start

    /// Starts a session, or leaves the machine exactly as it was.
    func start(request: SessionStartRequest) async throws(ServiceFailure) -> ActiveSession {
        // The lock file lives inside the runtime root, so the root has to exist before the
        // lock can be taken. On a clean machine it does not — which would make the very first
        // Start fail with a confusing "no such file" from the lock rather than doing anything.
        try runtimeFiles.prepareRuntimeRoot()

        do {
            return try await fileLock.withLock {
                try await self.performStart(request: request)
            }
        } catch let failure as ServiceFailure {
            throw failure
        } catch {
            throw ServiceFailure.internalError("\(error)")
        }
    }

    private func performStart(
        request: SessionStartRequest
    ) async throws(ServiceFailure) -> ActiveSession {

        // ---- Step 2: re-validate from scratch ---------------------------------------------
        guard request.protocolVersion == MacNetCoreInfo.protocolVersion else {
            throw ServiceFailure(
                code: .helperVersionMismatch,
                title: "Version Mismatch",
                message: "MacNetLab and its privileged helper are different versions.",
                recoverySuggestion: "Open Settings and choose Repair Helper.",
                technicalDetails: "request protocol \(request.protocolVersion), "
                    + "helper protocol \(MacNetCoreInfo.protocolVersion)",
                isRetryable: false
            )
        }

        let draft = request.draft
        let profile = draft.profileSnapshot

        // Ticket §5.3.5: the isolation confirmation travels inside the request so the helper
        // can refuse a start that lacks it, rather than trusting the UI to have asked.
        guard draft.safetyConfirmation || !profile.dhcpConfiguration.enabled else {
            throw ServiceFailure(
                code: .invalidRequest,
                title: "Confirmation Required",
                message: "Starting DHCP requires confirming that the selected interface is "
                    + "connected only to an isolated device network.",
                recoverySuggestion: "Tick the confirmation on the Overview page.",
                technicalDetails: nil,
                isRetryable: false
            )
        }

        // ---- Step 3: is something already running? -----------------------------------------
        try await refuseIfSessionActive()

        // ---- Step 4–5: identity and workspace ----------------------------------------------
        let validated: ValidatedSessionRequest
        do {
            validated = try ValidatedSessionRequest(
                profile: profile,
                interfaceBSDName: draft.selectedInterface.bsdName,
                systemDNSServers: draft.resolvedSystemDNSServers
            )
        } catch {
            throw Self.failure(for: error)
        }

        let live = try requireUsableInterface(named: validated.interfaceBSDName)
        let verification = try await executableVerifier.verifyBundledDnsmasq()

        let sessionID = UUID()
        // The root was already prepared before the lock was taken.
        let paths = try runtimeFiles.createSessionDirectory(sessionID: sessionID)

        // Everything from here can fail, and everything that has happened must be undone in
        // reverse. `rollback` accumulates the undo steps as they become necessary.
        var rollback = RollbackPlan(logger: logger)
        rollback.add(.removeSessionDirectory(sessionID))

        // ---- Step 6: journal before anything touches the system ----------------------------
        var journal = SessionJournal(
            sessionID: sessionID,
            state: .preparing,
            interfaceBSDName: validated.interfaceBSDName,
            serverIPv4: validated.serverIPv4,
            prefixLength: validated.subnet.prefixLength,
            aliasAddedByApp: false,
            interfaceWasUpBeforeStart: live.isUp,
            dnsmasqPID: nil,
            dnsmasqExecutableSHA256: verification.sha256,
            configurationPath: paths.configurationFile,
            leasePath: paths.leaseFile,
            logPath: paths.logFile,
            startedAt: nil,
            updatedAt: clock()
        )

        do {
            try journalStore.write(journal, now: clock())
            rollback.add(.clearJournal)

            // ---- Step 7: generate and write -------------------------------------------------
            let generated = generator.generate(request: validated, paths: RuntimePaths(
                sessionDirectory: paths.sessionDirectory
            ))
            try runtimeFiles.write(
                generated.configurationText, to: paths.configurationFile,
                ownership: .rootOwnedReadable
            )
            try runtimeFiles.write(
                generated.hostsText, to: paths.hostsFile, ownership: .rootOwnedReadable
            )

            // Read back and compare. A configuration that is not what the generator produced
            // means something else wrote it, and it is about to be handed to a root process.
            let writtenBack = try runtimeFiles.readFile(
                at: paths.configurationFile, maximumBytes: 1 << 20
            )
            guard writtenBack == generated.configurationText else {
                throw ServiceFailure.internalError(
                    "the configuration on disk is not what was generated"
                )
            }

            // ---- Step 8: pre-create what dnsmasq writes -------------------------------------
            // Created here, owned by `nobody`, so the session directory itself can stay
            // unwritable by the dropped-privilege process.
            for path in [paths.leaseFile, paths.logFile, paths.pidFile] {
                try runtimeFiles.createEmptyFile(at: path, ownership: .dnsmasqWritable)
            }

            // ---- Step 9: have dnsmasq check its own configuration ---------------------------
            try await runConfigurationTest(configurationPath: paths.configurationFile)

            // ---- Step 10: interface up ------------------------------------------------------
            if !live.isUp {
                try await aliasManager.setInterfaceUp(validated.interfaceBSDName, up: true)
                // Recorded so a session that brought it up puts it back down (ticket §15.2).
                rollback.add(.setInterfaceDown(validated.interfaceBSDName))
            }

            // ---- Step 11: the alias ---------------------------------------------------------
            let alreadyPresent = live.hasAddress(validated.serverIPv4)
            if profile.interfaceConfiguration.addTemporaryIPv4Alias && !alreadyPresent {
                try await aliasManager.addAlias(
                    interface: validated.interfaceBSDName,
                    address: validated.serverIPv4,
                    prefixLength: validated.subnet.prefixLength
                )
                rollback.add(.removeAlias(
                    interface: validated.interfaceBSDName, address: validated.serverIPv4
                ))
                journal = try journalStore.transition(journal, to: .aliasAdded, now: clock()) {
                    $0.aliasAddedByApp = true
                }
            }

            // ---- Step 12: re-check the ports, now that the address exists -------------------
            // Preflight checked these, and that answer is already stale. This is the one that
            // counts, and a conflict here rolls the alias straight back out (ticket §15.1).
            try await requirePortsAvailable(profile: profile, address: validated.serverIPv4)

            // ---- Steps 13–14: launch --------------------------------------------------------
            let launched = try await processController.launchDnsmasq(
                configurationPath: paths.configurationFile,
                workingDirectory: paths.sessionDirectory
            )
            rollback.add(.terminate(pid: launched.processIdentifier, digest: verification.sha256))

            journal = try journalStore.transition(journal, to: .processStarted, now: clock()) {
                $0.dnsmasqPID = launched.processIdentifier
            }

            // ---- Step 15: is it actually up? ------------------------------------------------
            try await confirmReadiness(
                pid: launched.processIdentifier,
                digest: verification.sha256,
                logPath: paths.logFile
            )

            // ---- Steps 16–18: commit --------------------------------------------------------
            let startedAt = clock()
            journal = try journalStore.transition(journal, to: .running, now: startedAt) {
                $0.startedAt = startedAt
            }

            let session = ActiveSession(
                id: sessionID,
                profileSnapshot: profile,
                interfaceSnapshot: live,
                startedAt: startedAt,
                helperVersion: HelperIdentity.version,
                dnsmasqVersion: verification.version,
                dnsmasqPID: launched.processIdentifier,
                aliasAddedByApp: journal.aliasAddedByApp
            )
            state = .running(session)
            startWatchingForUnexpectedExit(session: session, digest: verification.sha256)
            await startWatchingLeases(sessionID: sessionID, path: paths.leaseFile)

            logger.log(
                """
                session \(sessionID.uuidString, privacy: .public) running on \
                \(validated.interfaceBSDName, privacy: .public) pid=\(launched.processIdentifier, privacy: .public)
                """
            )
            return session

        } catch let failure as ServiceFailure {
            // ---- Step 15.2: unwind, in reverse -------------------------------------------
            await rollback.execute(
                aliasManager: aliasManager,
                processController: processController,
                runtimeFiles: runtimeFiles,
                journalStore: journalStore
            )
            state = .stopped
            throw failure
        } catch {
            await rollback.execute(
                aliasManager: aliasManager,
                processController: processController,
                runtimeFiles: runtimeFiles,
                journalStore: journalStore
            )
            state = .stopped
            throw ServiceFailure.internalError("\(error)")
        }
    }

    // MARK: - Start helpers

    private func refuseIfSessionActive() async throws(ServiceFailure) {
        // Checked three ways, because each can be true without the others: memory (this
        // process), the journal (a previous helper), and a live process.
        if let session = activeSession {
            throw Self.alreadyRunning(on: session.interfaceSnapshot.bsdName)
        }
        if let journal = journalStore.read(), journal.requiresCleanup {
            if let pid = journal.dnsmasqPID,
               case .runningAsExpected = processController.liveness(
                   of: pid, expectedExecutableSHA256: journal.dnsmasqExecutableSHA256
               ) {
                throw Self.alreadyRunning(on: journal.interfaceBSDName)
            }
            // A journal describing work that is no longer running must be cleaned up before
            // anything new starts, or its alias would be orphaned forever.
            _ = await recoverStaleState()
        }
    }

    private static func alreadyRunning(on interface: String) -> ServiceFailure {
        ServiceFailure(
            code: .invalidRequest,
            title: "A Session Is Already Running",
            message: "MacNetLab is already serving on \(interface).",
            recoverySuggestion: "Stop the current session before starting another.",
            technicalDetails: nil,
            isRetryable: false
        )
    }

    private func requireUsableInterface(
        named bsdName: String
    ) throws(ServiceFailure) -> NetworkInterfaceDescriptor {
        // Ticket §12.4: re-enumerated here, never taken from the request. The adapter may have
        // been unplugged, or the default route may have moved, since the app looked.
        guard let live = enumerator.enumerateInterfaces().first(where: { $0.bsdName == bsdName })
        else {
            throw ServiceFailure(
                code: .interfaceNotFound,
                title: "Interface Not Found",
                message: "\(bsdName) is no longer connected to this Mac.",
                recoverySuggestion: "Reconnect the adapter and try again.",
                technicalDetails: nil,
                isRetryable: true
            )
        }

        if let rejection = InterfaceSupportPolicy.rejection(
            bsdName: live.bsdName, kind: live.kind, isDefaultRoute: live.isDefaultRoute
        ) {
            throw ServiceFailure(
                code: rejection == .isWiFi ? .interfaceIsWiFi
                    : rejection == .isDefaultRoute ? .interfaceIsDefaultRoute
                    : .interfaceNotSupported,
                title: "Interface Not Supported",
                message: rejection.message,
                recoverySuggestion: "Choose a wired adapter connected to your device network.",
                technicalDetails: nil,
                isRetryable: false
            )
        }
        return live
    }

    private func runConfigurationTest(configurationPath: String) async throws(ServiceFailure) {
        let result: CommandResult
        do {
            result = try await commandRunner.run(
                .bundledDnsmasq,
                arguments: ["--test", "--conf-file=\(configurationPath)"],
                currentDirectory: nil,
                timeout: .seconds(10)
            )
        } catch let failure as ServiceFailure {
            throw failure
        } catch {
            throw ServiceFailure.internalError("could not run dnsmasq --test: \(error)")
        }

        guard result.succeeded else {
            let detail = (result.standardError + result.standardOutput)
                .split(separator: "\n").suffix(100).joined(separator: "\n")
            throw ServiceFailure(
                code: .dnsmasqConfigInvalid,
                title: "Generated Configuration Is Invalid",
                message: "dnsmasq rejected the configuration MacNetLab generated.",
                recoverySuggestion: "This is a MacNetLab problem. Please report it.",
                technicalDetails: detail,
                isRetryable: false
            )
        }
    }

    private func requirePortsAvailable(
        profile: NetworkProfile,
        address: IPv4Address
    ) async throws(ServiceFailure) {
        var required: [ProbedPort] = []
        if profile.dhcpConfiguration.enabled { required.append(.dhcpServer) }
        if profile.dnsConfiguration.enabled { required.append(.dnsUDP); required.append(.dnsTCP) }

        for port in required {
            // Only `inUse` blocks. An indeterminate probe means the check could not be
            // performed, which says nothing about the port — dnsmasq's own bind will decide.
            guard case .inUse = portProbe.probe(port, boundTo: address) else { continue }

            let holder = await PortConflictDiagnostics(commandRunner: commandRunner)
                .describeHolder(of: port)
            throw ServiceFailure(
                code: .portInUse,
                title: "Port Already In Use",
                message: holder.map {
                    "\(port.isTCP ? "TCP" : "UDP") port \(port.number) is in use by \($0)."
                } ?? "\(port.isTCP ? "TCP" : "UDP") port \(port.number) is already in use.",
                recoverySuggestion: port == .dhcpServer
                    ? "Another DHCP server is running. Stop it and try again."
                    : "Another DNS server is running. Stop it, or turn off DNS.",
                technicalDetails: "detected after the address was configured",
                isRetryable: true
            )
        }
    }

    /// Waits until dnsmasq looks healthy, or gives up (ticket §15.1 step 15).
    private func confirmReadiness(
        pid: Int32,
        digest: String,
        logPath: String
    ) async throws(ServiceFailure) {
        // 750 ms of staying alive is the signal. dnsmasq that is going to fail on a bad
        // interface or a taken port does so almost immediately, so surviving this long without
        // exiting is a much better indicator than anything parseable from the log.
        let settleTime = Duration.milliseconds(750)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))

        try? await Task.sleep(for: settleTime)

        while ContinuousClock.now < deadline {
            switch processController.liveness(of: pid, expectedExecutableSHA256: digest) {
            case .runningAsExpected:
                return
            case .notRunning, .identityMismatch:
                let tail = (try? runtimeFiles.readFile(at: logPath, maximumBytes: 64 * 1024))
                    .map { $0.split(separator: "\n").suffix(100).joined(separator: "\n") }

                throw ServiceFailure(
                    code: .processStartFailed,
                    title: "dnsmasq Stopped Immediately",
                    message: "The DNS and DHCP engine started and then exited.",
                    recoverySuggestion:
                        "Check the details below; the address or a port may already be in use.",
                    technicalDetails: tail,
                    isRetryable: true
                )
            }
        }

        throw ServiceFailure(
            code: .processStartFailed,
            title: "dnsmasq Did Not Become Ready",
            message: "The DNS and DHCP engine did not reach a running state.",
            recoverySuggestion: "Try again.",
            technicalDetails: "pid \(pid) was still not confirmed after 3 seconds",
            isRetryable: true
        )
    }

    // MARK: - Stop

    func stop(sessionID: UUID) async throws(ServiceFailure) {
        try runtimeFiles.prepareRuntimeRoot()

        do {
            try await fileLock.withLock {
                try await self.performStop(sessionID: sessionID)
            }
        } catch let failure as ServiceFailure {
            throw failure
        } catch {
            throw ServiceFailure.internalError("\(error)")
        }
    }

    private func performStop(sessionID: UUID) async throws(ServiceFailure) {
        guard let session = activeSession, session.id == sessionID else {
            // Stopping something that is not running is not an error: the app may be retrying
            // after a dropped connection, and the desired end state has already been reached.
            logger.log("stop requested for a session that is not running; nothing to do")
            state = .stopped
            journalStore.clear()
            return
        }

        state = .stopping
        exitWatcher?.cancel()
        exitWatcher = nil
        await leaseWatcher?.stop()
        leaseWatcher = nil

        var journal = journalStore.read()
        if let current = journal {
            journal = try? journalStore.transition(current, to: .stopping, now: clock())
        }

        var warnings: [String] = []

        // Steps 7–9: terminate, escalating only after re-verifying identity.
        do {
            try await processController.terminate(
                processIdentifier: session.dnsmasqPID,
                expectedExecutableSHA256: journal?.dnsmasqExecutableSHA256 ?? "",
                gracePeriod: .seconds(5)
            )
        } catch {
            // A stale PID is not a reason to skip removing the alias — that is the part the
            // user's machine is left holding.
            warnings.append(error.message)
            logger.error("could not stop dnsmasq cleanly: \(error.message, privacy: .public)")
        }

        // Step 12: remove only what this app added (ticket §13.2).
        if session.aliasAddedByApp {
            do {
                try await aliasManager.removeAlias(
                    interface: session.interfaceSnapshot.bsdName,
                    address: session.profileSnapshot.interfaceConfiguration.serverIPv4
                )
            } catch {
                // Reported, never hidden. The user is left with an address on their Mac.
                logger.fault("alias removal failed: \(error.message, privacy: .public)")
                state = .failed(error)
                if let journal {
                    _ = try? journalStore.transition(journal, to: .cleanupRequired, now: clock())
                }
                throw error
            }
        }

        // Step 13: put the interface back as it was found.
        if let journal, !journal.interfaceWasUpBeforeStart {
            try? await aliasManager.setInterfaceUp(journal.interfaceBSDName, up: false)
        }

        // Steps 15–18: clear the record, keep the logs.
        journalStore.clear()
        state = .stopped

        logger.log("session \(sessionID.uuidString, privacy: .public) stopped")
        if !warnings.isEmpty {
            logger.log("stop completed with warnings: \(warnings.joined(separator: "; "), privacy: .public)")
        }
    }

    // MARK: - Recovery

    /// Reconciles the journal with reality (ticket §17.3).
    func recoverStaleState() async -> RecoveryReport {
        guard let journal = journalStore.read() else {
            return RecoveryReport(outcome: .nothingToRecover)
        }
        guard journal.requiresCleanup else {
            journalStore.clear()
            return RecoveryReport(outcome: .nothingToRecover)
        }

        // Case B: the process is still there and still ours. Re-adopt it rather than killing
        // and restarting — the user's devices are holding leases from it.
        if let pid = journal.dnsmasqPID,
           case .runningAsExpected = processController.liveness(
               of: pid, expectedExecutableSHA256: journal.dnsmasqExecutableSHA256
           ) {
            logger.log("re-adopting running session \(journal.sessionID.uuidString, privacy: .public)")
            return RecoveryReport(
                outcome: .reattachedToRunningSession,
                warnings: [],
                recoveredSession: nil
            )
        }

        // Case D: alive, but not ours. Signal nothing (ticket §17.3).
        if let pid = journal.dnsmasqPID,
           case .identityMismatch(let actualPath) = processController.liveness(
               of: pid, expectedExecutableSHA256: journal.dnsmasqExecutableSHA256
           ) {
            journalStore.archiveForDiagnosis(
                journal, reason: "pid \(pid) is now \(actualPath ?? "unidentifiable")"
            )
            var warnings = [
                "Process \(pid) is no longer MacNetLab's and was left alone."
            ]
            warnings.append(contentsOf: await removeOrphanedAlias(journal))
            journalStore.clear()
            return RecoveryReport(outcome: .staleSessionRequiresAttention, warnings: warnings)
        }

        // Case C: the process is gone. Clean up what it left.
        let warnings = await removeOrphanedAlias(journal)
        try? runtimeFiles.removeSessionDirectory(sessionID: journal.sessionID)
        journalStore.clear()
        state = .stopped

        return RecoveryReport(
            outcome: warnings.isEmpty ? .cleanedUpAfterDeadProcess : .cleanupIncomplete,
            warnings: warnings
        )
    }

    /// Removes an alias the previous session added, returning any warnings.
    private func removeOrphanedAlias(_ journal: SessionJournal) async -> [String] {
        guard journal.aliasAddedByApp else { return [] }

        do {
            try await aliasManager.removeAlias(
                interface: journal.interfaceBSDName, address: journal.serverIPv4
            )
            logger.log("removed orphaned alias \(journal.serverIPv4.description, privacy: .public)")
            return []
        } catch {
            return [error.recoverySuggestion.map {
                "\(error.message) \($0)"
            } ?? error.message]
        }
    }

    // MARK: - Leases

    /// Latest leases for a session, for a client that has just asked.
    ///
    /// Returns an empty snapshot rather than an error when nothing is running: "no session" is
    /// a state the Leases page renders on purpose (ticket §5.4), not a failure.
    func leaseSnapshot(sessionID: UUID) async -> LeaseSnapshot {
        guard let watcher = leaseWatcher, activeSession?.id == sessionID else {
            return LeaseSnapshot(
                sessionID: sessionID, leases: [], readAt: clock(), malformedLineCount: 0
            )
        }
        return await watcher.currentSnapshot()
    }

    private func startWatchingLeases(sessionID: UUID, path: String) async {
        await leaseWatcher?.stop()

        let watcher = LeaseFileWatcher(
            sessionID: sessionID,
            path: path,
            clock: clock
        ) { [weak self] snapshot in
            Task { await self?.publishLeaseSnapshot(snapshot) }
        }
        leaseWatcher = watcher
        await watcher.start()
    }

    private func publishLeaseSnapshot(_ snapshot: LeaseSnapshot) {
        // Pushed rather than polled, so a device appearing shows up in under the two seconds
        // ticket §25 asks for without the app asking every second.
        leaseSnapshotHandler?(snapshot)
    }

    /// Notified whenever the lease set changes.
    private var leaseSnapshotHandler: (@Sendable (LeaseSnapshot) -> Void)?

    func setLeaseSnapshotHandler(_ handler: @escaping @Sendable (LeaseSnapshot) -> Void) {
        leaseSnapshotHandler = handler
    }

    // MARK: - Unexpected exit

    /// Watches for dnsmasq exiting without being asked (ticket §17.4).
    ///
    /// Polled rather than driven by a termination handler, because the helper may have adopted
    /// a process it did not spawn — after its own restart — and has no `Process` object for it.
    /// A verified PID is enough to manage a session (ticket §17.3 case B).
    private func startWatchingForUnexpectedExit(session: ActiveSession, digest: String) {
        exitWatcher?.cancel()
        exitWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard await self.handleExitCheck(session: session, digest: digest) else { return }
            }
        }
    }

    /// One poll. Returns `false` when watching should stop.
    private func handleExitCheck(session: ActiveSession, digest: String) async -> Bool {
        guard case .running(let current) = state, current.id == session.id else { return false }

        switch processController.liveness(
            of: session.dnsmasqPID, expectedExecutableSHA256: digest
        ) {
        case .runningAsExpected:
            return true

        case .notRunning, .identityMismatch:
            logger.fault("dnsmasq exited unexpectedly for session \(session.id.uuidString, privacy: .public)")

            let logPath = journalStore.read()?.logPath
            let tail = logPath
                .flatMap { try? runtimeFiles.readFile(at: $0, maximumBytes: 64 * 1024) }
                .map { $0.split(separator: "\n").suffix(100).map(String.init) } ?? []

            await leaseWatcher?.stop()
            leaseWatcher = nil

            let warnings = await removeOrphanedAlias(
                journalStore.read() ?? Self.syntheticJournal(for: session, digest: digest)
            )
            journalStore.clear()
            state = .stopped

            // Ticket §17.4: never restart automatically. A crash loop against a network the
            // user cannot see would be far worse than a stopped service they can.
            unexpectedExitHandler?(UnexpectedExitReport(
                sessionID: session.id,
                exitStatus: nil,
                recentLogLines: tail,
                cleanupSucceeded: warnings.isEmpty,
                cleanupWarnings: warnings
            ))
            return false
        }
    }

    /// Reconstructs enough of a journal to clean up, when the real one is gone.
    private static func syntheticJournal(
        for session: ActiveSession, digest: String
    ) -> SessionJournal {
        SessionJournal(
            sessionID: session.id,
            state: .cleanupRequired,
            interfaceBSDName: session.interfaceSnapshot.bsdName,
            serverIPv4: session.profileSnapshot.interfaceConfiguration.serverIPv4,
            prefixLength: session.profileSnapshot.interfaceConfiguration.prefixLength,
            aliasAddedByApp: session.aliasAddedByApp,
            interfaceWasUpBeforeStart: true,
            dnsmasqPID: session.dnsmasqPID,
            dnsmasqExecutableSHA256: digest,
            configurationPath: "",
            leasePath: "",
            logPath: "",
            startedAt: session.startedAt,
            updatedAt: session.startedAt
        )
    }

    private static func failure(for error: ValidatedSessionRequest.Failure) -> ServiceFailure {
        switch error {
        case .interfaceName:
            ServiceFailure(
                code: .interfaceNotSupported,
                title: "Interface Not Supported",
                message: "MacNetLab will not configure the selected interface.",
                isRetryable: false
            )
        case .configuration(let issues):
            ServiceFailure(
                code: .invalidRequest,
                title: "Invalid Configuration",
                message: issues.first?.message ?? "The configuration is not valid.",
                technicalDetails: issues.map(\.id).joined(separator: ", "),
                isRetryable: false
            )
        case .noUsableSystemDNSServers:
            ServiceFailure(
                code: .invalidDNSConfiguration,
                title: "No System DNS Servers",
                message: "This Mac has no usable DNS servers to forward to.",
                recoverySuggestion: "Choose Custom DNS or Local Records Only instead.",
                isRetryable: false
            )
        }
    }
}

/// The undo steps for a start in progress.
///
/// Kept as data rather than as nested `defer` blocks so that the unwind order is explicit and
/// readable: steps run in exactly the reverse of the order they were added (ticket §15.2).
struct RollbackPlan {

    enum Step {
        case removeSessionDirectory(UUID)
        case clearJournal
        case setInterfaceDown(String)
        case removeAlias(interface: String, address: IPv4Address)
        case terminate(pid: Int32, digest: String)
    }

    private var steps: [Step] = []
    let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    mutating func add(_ step: Step) {
        steps.append(step)
    }

    /// Runs every step in reverse, continuing past failures.
    ///
    /// Continuing is deliberate: if terminating the process fails, the alias must still be
    /// removed. Stopping at the first failure would leave more behind than proceeding does.
    func execute(
        aliasManager: any InterfaceAliasManaging,
        processController: any ProcessControlling,
        runtimeFiles: RuntimeFileManager,
        journalStore: SessionJournalStore
    ) async {
        for step in steps.reversed() {
            switch step {
            case .terminate(let pid, let digest):
                try? await processController.terminate(
                    processIdentifier: pid,
                    expectedExecutableSHA256: digest,
                    gracePeriod: .seconds(3)
                )

            case .removeAlias(let interface, let address):
                do {
                    try await aliasManager.removeAlias(interface: interface, address: address)
                } catch {
                    // The one failure a user must be told about even during rollback: their
                    // Mac is left holding an address.
                    logger.fault(
                        """
                        rollback could not remove \(address.description, privacy: .public) \
                        from \(interface, privacy: .public)
                        """
                    )
                }

            case .setInterfaceDown(let interface):
                try? await aliasManager.setInterfaceUp(interface, up: false)

            case .clearJournal:
                journalStore.clear()

            case .removeSessionDirectory(let sessionID):
                try? runtimeFiles.removeSessionDirectory(sessionID: sessionID)
            }
        }
    }
}
