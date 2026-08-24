import Foundation
import MacNetDnsmasq
import MacNetInterfaces
import MacNetModels
import MacNetValidation
import MacNetXPC
import OSLog

/// Runs the read-only checks that decide whether a session could start (ticket §14).
///
/// ## Read-only means read-only
///
/// Preflight adds no alias, starts no process, stops nothing, and changes no network
/// configuration. That is what lets the UI run it freely — on every edit, if it wants — without
/// the user wondering whether pressing Validate did something.
///
/// ## Preflight is advisory
///
/// Its answer is already stale by the time the user reads it: a port can be taken, an adapter
/// unplugged, an address configured by something else. The authoritative checks are the ones
/// inside the start transaction, which re-run everything (ticket §15.1 step 2). Preflight
/// exists to tell the user what is wrong *before* they commit, not to grant permission.
struct PreflightRunner: Sendable {

    let enumerator: any InterfaceEnumerating
    let portProbe: any PortProbing
    let executableVerifier: any ExecutableVerifying
    let commandRunner: any CommandRunning
    let fileManager: RuntimeFileManager

    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "preflight")

    /// Runs every check, in the order given by ticket §14.1.
    ///
    /// Order matters for the *user*, not the machine: a report that leads with "the interface
    /// is Wi-Fi" is more useful than one leading with "the generated configuration is invalid"
    /// when both are consequences of the same wrong choice.
    func run(
        request: SessionStartRequest,
        existingSession: ActiveSession?,
        now: Date
    ) async -> PreflightReport {
        var issues: [PreflightIssue] = []
        var statuses: [PreflightCheck: PreflightCheckStatus] = [:]
        var configurationTestOutput: String?

        func record(_ check: PreflightCheck, _ status: PreflightCheckStatus) {
            // Never downgrade: a check that already failed stays failed even if a later, more
            // specific finding is only a warning.
            let existing = statuses[check]
            if existing == .failed { return }
            if existing == .warning && status == .passed { return }
            statuses[check] = status
        }

        func fail(_ check: PreflightCheck, _ issue: PreflightIssue) {
            issues.append(issue)
            record(check, issue.severity == .error ? .failed : .warning)
        }

        // ---- Steps 1–3: the request itself -------------------------------------------------
        record(.helperInstalled, .passed)

        guard request.protocolVersion == MacNetCoreInfo.protocolVersion else {
            fail(.helperVersionCompatible, PreflightIssue(
                id: "protocol.mismatch",
                severity: .error,
                title: "Version Mismatch",
                message: "This request was built for protocol \(request.protocolVersion), "
                    + "but the helper speaks \(MacNetCoreInfo.protocolVersion).",
                recoverySuggestion: "Open Settings and choose Repair Helper."
            ))
            return report(statuses: statuses, issues: issues, output: nil, now: now)
        }
        record(.helperVersionCompatible, .passed)

        let draft = request.draft
        let profile = draft.profileSnapshot

        // ---- Step 4: full validation, re-run here -----------------------------------------
        // The app validated this. That is irrelevant: ticket §7 makes helper-side validation
        // the security boundary, and nothing the app says is taken on trust.
        let validationIssues = ConfigurationValidator.validate(profile)
        for issue in validationIssues where issue.severity == .error {
            fail(check(for: issue.field), PreflightIssue(
                id: issue.id,
                severity: .error,
                title: "Invalid Configuration",
                message: issue.message
            ))
        }
        for issue in validationIssues where issue.severity == .warning {
            fail(check(for: issue.field), PreflightIssue(
                id: issue.id,
                severity: .warning,
                title: "Check This Setting",
                message: issue.message
            ))
        }
        if !validationIssues.contains(where: { $0.severity == .error }) {
            record(.ipv4ConfigurationValid, .passed)
            record(.dhcpPoolValid, .passed)
            record(.dnsConfigurationValid, .passed)
        }

        // ---- Step 5: is something already running? -----------------------------------------
        if let existingSession {
            fail(.helperInstalled, PreflightIssue(
                id: "session.alreadyRunning",
                severity: .error,
                title: "A Session Is Already Running",
                message: "MacNetLab is already serving on "
                    + "\(existingSession.interfaceSnapshot.bsdName).",
                recoverySuggestion: "Stop the current session before starting another."
            ))
        }

        // ---- Steps 6–11: the engine --------------------------------------------------------
        do {
            let verification = try await executableVerifier.verifyBundledDnsmasq()
            record(.dnsmasqBinaryVerified, .passed)
            logger.debug("dnsmasq verified: \(verification.version, privacy: .public)")
        } catch {
            fail(.dnsmasqBinaryVerified, PreflightIssue(
                id: "dnsmasq.verificationFailed",
                severity: .error,
                title: error.title,
                message: error.message,
                recoverySuggestion: error.recoverySuggestion
            ))
        }

        // ---- Steps 12–17: the interface, as it is *now* ------------------------------------
        let liveInterfaces = enumerator.enumerateInterfaces()
        let bsdName = draft.selectedInterface.bsdName

        guard let live = liveInterfaces.first(where: { $0.bsdName == bsdName }) else {
            fail(.interfaceSupported, PreflightIssue(
                id: "interface.missing",
                severity: .error,
                title: "Interface Not Found",
                message: "\(bsdName) is no longer connected to this Mac.",
                recoverySuggestion: "Reconnect the adapter, then refresh."
            ))
            return report(statuses: statuses, issues: issues, output: nil, now: now)
        }

        // The app's snapshot is not trusted; support is decided from what was just enumerated.
        if let rejection = InterfaceSupportPolicy.rejection(
            bsdName: live.bsdName, kind: live.kind, isDefaultRoute: live.isDefaultRoute
        ) {
            let check: PreflightCheck = rejection == .isDefaultRoute
                ? .interfaceIsNotDefaultRoute : .interfaceSupported
            fail(check, PreflightIssue(
                id: "interface.rejected",
                severity: .error,
                title: "Interface Not Supported",
                message: rejection.message
            ))
        } else {
            record(.interfaceSupported, .passed)
            record(.interfaceIsNotDefaultRoute, .passed)
        }

        // Link down is only a warning: in a datacenter the device on the other end is very
        // often not powered on yet (ticket §21.6).
        if !live.isLinkActive {
            fail(.interfaceSupported, PreflightIssue(
                id: "interface.noLink",
                severity: .warning,
                title: "No Link Detected",
                message: "Nothing is detected on \(bsdName). "
                    + "This is expected if the device is not powered on yet.",
                recoverySuggestion: "Check the cable and that the device has power."
            ))
        }

        let serverAddress = profile.interfaceConfiguration.serverIPv4
        if let existing = live.existingEntry(for: serverAddress),
           existing.prefixLength != profile.interfaceConfiguration.prefixLength {
            fail(.ipv4ConfigurationValid, PreflightIssue(
                id: "interface.addressPrefixConflict",
                severity: .error,
                title: "Address Already Configured Differently",
                message: "\(serverAddress) is already on \(bsdName) with a different subnet mask.",
                recoverySuggestion: "Choose a different server address, or remove the existing one."
            ))
        }

        // ---- Steps 22–25: does the generated configuration actually parse? -----------------
        // The only way to know is to have dnsmasq read it, which is what `--test` is for.
        if !issues.contains(where: { $0.severity == .error }) {
            let outcome = await testGeneratedConfiguration(
                profile: profile,
                interfaceBSDName: bsdName,
                systemDNSServers: draft.resolvedSystemDNSServers
            )
            configurationTestOutput = outcome.output

            if let failure = outcome.issue {
                fail(.generatedConfigurationValid, failure)
            } else {
                record(.generatedConfigurationValid, .passed)
            }
        }

        // ---- Steps 26–27: ports ------------------------------------------------------------
        // Probed on the wildcard address, because the server address is not on the interface
        // yet — adding it is a side effect, and preflight has none. That makes this check
        // broader than the real one, which is the safe direction: it can warn about a
        // conflict that would not have mattered, but it will not miss one that would.
        issues.append(contentsOf: await probePorts(profile: profile, statuses: &statuses))

        return report(
            statuses: statuses, issues: issues, output: configurationTestOutput, now: now
        )
    }

    // MARK: - Configuration test

    private func testGeneratedConfiguration(
        profile: NetworkProfile,
        interfaceBSDName: String,
        systemDNSServers: [IPv4Address]
    ) async -> (issue: PreflightIssue?, output: String?) {
        let validated: ValidatedSessionRequest
        do {
            validated = try ValidatedSessionRequest(
                profile: profile,
                interfaceBSDName: interfaceBSDName,
                systemDNSServers: systemDNSServers
            )
        } catch {
            return (PreflightIssue(
                id: "configuration.notBuildable",
                severity: .error,
                title: "Configuration Cannot Be Built",
                message: Self.describe(error),
                recoverySuggestion: "Check the DNS and DHCP settings."
            ), nil)
        }

        // Written into a throwaway directory that is removed afterwards (ticket §14.1 step 28),
        // so preflight leaves nothing behind even on the failure path.
        let scratchID = UUID()
        let scratch = NSTemporaryDirectory() + "macnetlab-preflight-\(scratchID.uuidString)"
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        do {
            try FileManager.default.createDirectory(
                atPath: scratch, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return (nil, "could not create a temporary directory: \(error)")
        }

        let paths = RuntimePaths(sessionDirectory: scratch)
        let generated = DnsmasqConfigurationGenerator().generate(request: validated, paths: paths)

        do {
            try Data(generated.configurationText.utf8)
                .write(to: URL(fileURLWithPath: paths.configurationFile))
            try Data(generated.hostsText.utf8)
                .write(to: URL(fileURLWithPath: paths.hostsFile))
        } catch {
            return (nil, "could not write the test configuration: \(error)")
        }

        let result: CommandResult
        do {
            result = try await commandRunner.run(
                .bundledDnsmasq,
                arguments: ["--test", "--conf-file=\(paths.configurationFile)"],
                currentDirectory: scratch,
                timeout: .seconds(10)
            )
        } catch {
            return (PreflightIssue(
                id: "configuration.testFailed",
                severity: .error,
                title: "Could Not Check Configuration",
                message: "The configuration check could not be run.",
                recoverySuggestion: "Try again. If it keeps happening, reinstall MacNetLab."
            ), "\(error)")
        }

        let output = (result.standardError + result.standardOutput)
            .split(separator: "\n")
            .suffix(100)                    // ticket §9.10: the last 100 lines
            .joined(separator: "\n")

        guard result.succeeded else {
            return (PreflightIssue(
                id: "configuration.invalid",
                severity: .error,
                title: "Generated Configuration Is Invalid",
                message: "dnsmasq rejected the configuration MacNetLab generated.",
                recoverySuggestion: "This is a MacNetLab problem. Please report it with the details below."
            ), output)
        }
        return (nil, output.isEmpty ? nil : output)
    }

    private static func describe(_ failure: ValidatedSessionRequest.Failure) -> String {
        switch failure {
        case .interfaceName:
            "The selected interface cannot be used."
        case .configuration(let issues):
            issues.first?.message ?? "The configuration is not valid."
        case .noUsableSystemDNSServers:
            "This Mac has no usable DNS servers to forward to. "
                + "Choose Custom DNS or Local Records Only instead."
        }
    }

    // MARK: - Ports

    private func probePorts(
        profile: NetworkProfile,
        statuses: inout [PreflightCheck: PreflightCheckStatus]
    ) async -> [PreflightIssue] {
        var required: [ProbedPort] = []
        if profile.dhcpConfiguration.enabled { required.append(.dhcpServer) }
        if profile.dnsConfiguration.enabled { required.append(.dnsUDP); required.append(.dnsTCP) }

        guard !required.isEmpty else {
            statuses[.requiredPortsAvailable] = .passed
            return []
        }

        var issues: [PreflightIssue] = []
        var allAvailable = true

        let diagnostics = PortConflictDiagnostics(commandRunner: commandRunner)

        for port in required {
            switch portProbe.probe(port, boundTo: .any) {
            case .available:
                continue

            case .inUse:
                allAvailable = false
                // `lsof` runs only after a bind has already failed, purely to name the holder.
                // Its own failure changes nothing (ticket §14.3).
                let holder = await diagnostics.describeHolder(of: port)
                issues.append(PreflightIssue(
                    id: "port.inUse.\(port.number)\(port.isTCP ? "tcp" : "udp")",
                    severity: .error,
                    title: "Port Already In Use",
                    message: holder.map {
                        "\(port.isTCP ? "TCP" : "UDP") port \(port.number) is in use by \($0)."
                    } ?? "\(port.isTCP ? "TCP" : "UDP") port \(port.number) is already in use.",
                    recoverySuggestion: port == .dhcpServer
                        ? "Another DHCP server is running on this Mac. Stop it and try again."
                        : "Another DNS server is running on this Mac. Stop it, or turn off DNS."
                ))

            case .indeterminate(let reason):
                // Reported as a warning, never as a conflict: a probe that could not run says
                // nothing about the port, and blocking Start for it would be wrong.
                allAvailable = false
                issues.append(PreflightIssue(
                    id: "port.indeterminate.\(port.number)\(port.isTCP ? "tcp" : "udp")",
                    severity: .warning,
                    title: "Could Not Check Port",
                    message: "MacNetLab could not confirm that "
                        + "\(port.isTCP ? "TCP" : "UDP") port \(port.number) is free.",
                    recoverySuggestion: "Starting will check again and stop if it is taken."
                ))
                _ = reason
            }
        }

        statuses[.requiredPortsAvailable] = allAvailable
            ? .passed
            : (issues.contains { $0.severity == .error } ? .failed : .warning)
        return issues
    }

    // MARK: - Assembly

    private func check(for field: ValidationField) -> PreflightCheck {
        switch field {
        case .serverIPv4, .prefixLength: .ipv4ConfigurationValid
        case .dhcpEnabled, .dhcpRangeStart, .dhcpRangeEnd,
             .dhcpLeaseDuration, .dhcpRouter: .dhcpPoolValid
        case .dnsEnabled, .dnsLocalDomain, .dnsUpstreamServers, .dnsRecords: .dnsConfigurationValid
        case .profileName, .services: .ipv4ConfigurationValid
        }
    }

    private func report(
        statuses: [PreflightCheck: PreflightCheckStatus],
        issues: [PreflightIssue],
        output: String?,
        now: Date
    ) -> PreflightReport {
        // Every check appears, including ones that never ran — the UI shows the full list so
        // the user can see what was checked, not only what failed (ticket §5.3.6).
        let results = PreflightCheck.allCases.map { check in
            PreflightCheckResult(
                check: check,
                status: statuses[check] ?? .pending,
                issueIDs: []
            )
        }
        return PreflightReport(
            checks: results, issues: issues, configurationTestOutput: output, generatedAt: now
        )
    }
}
