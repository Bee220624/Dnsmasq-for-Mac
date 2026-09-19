#if DEBUG
import Foundation
import MacNetInterfaces
import MacNetModels
import MacNetXPC

/// A DEBUG-only, all-or-nothing fixture. It never constructs a real helper or accepts paths.
enum UITestFixture {
    enum Scenario: String { case ready, notRegistered, approval, bundleIncomplete, incompatible, failed }
    enum SelectionError: Error { case invalidScenario }

    @MainActor
    static func dependencies(scenario rawValue: String) throws -> AppDependencies {
        guard let scenario = Scenario(rawValue: rawValue) else { throw SelectionError.invalidScenario }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DnsmasqForMac-UITest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return AppDependencies(
            helper: UITestHelperClient(scenario: scenario),
            profiles: ProfileLibrary(store: ProfileStore(directory: directory)),
            interfaces: InterfaceMonitor(enumerator: UITestInterfaces(), watchesSystemChanges: false),
            sessionRequests: SessionRequestBuilder(resolveSystemDNSServers: {
                [IPv4Address(rawValue: 0xC000_0235)] // 192.0.2.53, reserved for documentation.
            }),
            fixtureProfileDirectory: directory
        )
    }
}

private struct UITestInterfaces: InterfaceEnumerating {
    func enumerateInterfaces() -> [NetworkInterfaceDescriptor] {
        [NetworkInterfaceDescriptor(
            bsdName: "fixture0", displayName: "Fixture Ethernet", hardwarePortName: nil,
            kind: .ethernet, macAddress: "02:00:00:00:00:01", ipv4Addresses: [], isUp: true,
            isRunning: true, isLinkActive: true, isDefaultRoute: false, isSupported: true,
            unsupportedReason: nil
        )]
    }
}

/// Every button terminates here. No SMAppService, XPC, subprocess or socket is reachable.
actor UITestHelperClient: HelperLifecycleClient {
    private var scenario: UITestFixture.Scenario
    private var failedOnce = false
    init(scenario: UITestFixture.Scenario) { self.scenario = scenario }

    func installationState() -> HelperInstallationState {
        switch scenario {
        case .notRegistered: .notRegistered
        case .approval: .requiresApproval
        case .bundleIncomplete: .bundleIncomplete
        default: .enabled
        }
    }
    func handshake() -> HelperReadiness {
        let installation = installationState()
        guard installation.isConnectable else { return .notInstalled(installation) }
        if scenario == .failed, !failedOnce {
            failedOnce = true
            return .failed(ServiceFailure(code: .helperUnavailable, title: "Fixture Helper Unavailable",
                                          message: "Simulated XPC failure; retry is safe.", isRetryable: true))
        }
        let info = HelperServiceInfoSnapshot(HelperServiceInfo(
            helperVersion: "UI fixture", protocolVersion: 1, effectiveUID: 0,
            buildType: .debug, bundleIdentifier: "ui.fixture", engineVerification: nil
        ))
        if scenario == .incompatible { return .incompatible(info, reason: "Simulated protocol mismatch.") }
        return .ready(info)
    }
    func install() -> HelperInstallationState { scenario = .approval; return .requiresApproval }
    func uninstall() { scenario = .notRegistered }
    nonisolated func openLoginItemsSettings() {}
    func runtimeStatus() -> RuntimeState { .stopped }
    func recoverStaleState() -> RecoveryReport { RecoveryReport(outcome: .nothingToRecover) }
    func preflight(_ request: SessionStartRequest) -> PreflightReport {
        PreflightReport(checks: [], issues: [PreflightIssue(
            id: "ui.fixture", severity: .error, title: "UI Fixture", message: "Fixtures cannot start network services."
        )], generatedAt: Date())
    }
    func startSession(_ request: SessionStartRequest) throws(ServiceFailure) -> ActiveSession {
        throw ServiceFailure.invalidRequest("UI fixtures cannot start network services.")
    }
    func stopSession(id: UUID) {}
    func leaseSnapshot(sessionID: UUID) -> LeaseSnapshot {
        LeaseSnapshot(sessionID: sessionID, leases: [], readAt: Date(), malformedLineCount: 0)
    }
    func logSnapshot(sessionID: UUID, after sequence: Int64) -> LogBatch {
        LogBatch(sessionID: sessionID, events: [], highestSequence: sequence)
    }
}
#endif
