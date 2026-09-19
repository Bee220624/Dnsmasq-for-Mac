import Foundation
import Testing
import MacNetModels
import MacNetXPC

private actor TestSessionClient: SessionClient {
    var state: RuntimeState = .stopped
    var stopFailure: ServiceFailure?
    var runtimeFailure: ServiceFailure?
    var report = PreflightReport(checks: [], issues: [], generatedAt: Date())
    var recovery = RecoveryReport(outcome: .nothingToRecover)
    var sessionToStart: ActiveSession?
    var preflightCallCount = 0
    var startCallCount = 0

    func setState(_ value: RuntimeState) { state = value }
    func failRuntime(_ value: ServiceFailure?) { runtimeFailure = value }
    func failStop(_ value: ServiceFailure?) { stopFailure = value }
    func setReport(_ value: PreflightReport) { report = value }
    func setRecovery(_ value: RecoveryReport) { recovery = value }
    func setSessionToStart(_ value: ActiveSession?) { sessionToStart = value }
    func sessionOperationCallCounts() -> (preflight: Int, start: Int) {
        (preflightCallCount, startCallCount)
    }
    func runtimeStatus() async throws(ServiceFailure) -> RuntimeState {
        if let runtimeFailure { throw runtimeFailure }; return state
    }
    func recoverStaleState() async throws(ServiceFailure) -> RecoveryReport { recovery }
    func preflight(_ request: SessionStartRequest) async throws(ServiceFailure) -> PreflightReport {
        preflightCallCount += 1
        return report
    }
    func startSession(_ request: SessionStartRequest) async throws(ServiceFailure) -> ActiveSession {
        startCallCount += 1
        if let sessionToStart { return sessionToStart }
        throw ServiceFailure.invalidRequest("Not used by this fixture")
    }
    func stopSession(id: UUID) async throws(ServiceFailure) {
        if let stopFailure { throw stopFailure }
        state = .stopped
    }
}

@Suite("Session controller") @MainActor
struct SessionControllerTests {
    private func session() -> ActiveSession {
        let interface = NetworkInterfaceDescriptor(
            bsdName: "en7", displayName: "USB Ethernet", hardwarePortName: nil,
            kind: .ethernet, macAddress: "00:11:22:33:44:55", ipv4Addresses: [],
            isUp: true, isRunning: true, isLinkActive: true, isDefaultRoute: false,
            isSupported: true, unsupportedReason: nil
        )
        return ActiveSession(id: UUID(), profileSnapshot: .makeDefault(now: Date()),
                             interfaceSnapshot: interface, startedAt: Date(), helperVersion: "0.1.0",
                             dnsmasqVersion: "2.93", dnsmasqPID: 4242, aliasAddedByApp: true)
    }

    @Test("a transport error while stopping keeps the session available for retry")
    func failedStopRetainsSession() async {
        let client = TestSessionClient()
        let running = session()
        await client.setState(.running(running))
        let controller = SessionController(client: client)
        await controller.synchronize()
        await client.failStop(ServiceFailure(code: .helperUnavailable, title: "Disconnected", message: "No reply"))
        await controller.stop()
        #expect(controller.activeSession == running)
        #expect(controller.phase == .failed)
        #expect(!controller.canRemoveHelper)
        await client.failStop(nil)
        await controller.stop()
        #expect(controller.activeSession == nil)
        #expect(controller.phase == .stopped)
    }

    @Test("unresolved cleanup blocks preflight and start until stop retry succeeds", arguments: [
        RecoveryReport.Outcome.cleanupIncomplete, .staleSessionRequiresAttention
    ])
    func unresolvedRecovery(outcome: RecoveryReport.Outcome) async {
        let client = TestSessionClient()
        let running = session()
        let request = SessionStartRequest(draft: SessionDraft(
            profileSnapshot: running.profileSnapshot, selectedInterface: running.interfaceSnapshot,
            resolvedSystemDNSServers: [], safetyConfirmation: true
        ))
        await client.setRecovery(RecoveryReport(outcome: outcome, warnings: ["Needs cleanup"]))
        let controller = SessionController(client: client)
        await controller.synchronize()
        #expect(controller.phase == .failed)
        #expect(controller.lastFailure?.code == .cleanupFailed)
        #expect(controller.activeSession == nil)
        #expect(!controller.canRemoveHelper)
        #expect(!controller.canStart(profile: running.profileSnapshot, hasInterface: true, helperReady: true))

        await controller.runPreflight(request)
        await controller.start(request)
        let blockedCounts = await client.sessionOperationCallCounts()
        #expect(blockedCounts.preflight == 0)
        #expect(blockedCounts.start == 0)
        #expect(controller.phase == .failed)
        #expect(controller.lastFailure?.code == .cleanupFailed)
        #expect(!controller.canRemoveHelper)
        #expect(!controller.canStart(profile: running.profileSnapshot, hasInterface: true, helperReady: true))

        controller.clearFailure()
        #expect(controller.lastFailure?.code == .cleanupFailed)
        await controller.stop()
        #expect(controller.phase == .failed)
        #expect(controller.lastFailure?.code == .cleanupFailed)
        await client.setRecovery(RecoveryReport(outcome: .nothingToRecover))
        await controller.stop()
        #expect(controller.phase == .stopped)
        #expect(controller.lastFailure == nil)
        #expect(controller.canRemoveHelper)

        await client.setSessionToStart(running)
        await controller.runPreflight(request)
        await controller.start(request)
        let allowedCounts = await client.sessionOperationCallCounts()
        #expect(allowedCounts.preflight == 1)
        #expect(allowedCounts.start == 1)
        #expect(controller.activeSession == running)
    }

    @Test("removal requires known stopped state and completed recovery")
    func removalAvailability() async {
        let client = TestSessionClient()
        let controller = SessionController(client: client)
        #expect(!controller.canRemoveHelper)
        await controller.synchronize()
        #expect(controller.canRemoveHelper)
        for state in [RuntimeState.preflighting, .starting, .stopping, .recovering, .running(session()),
                      .failed(ServiceFailure.internalError("unknown state"))] {
            await client.setState(state)
            await controller.synchronize()
            #expect(!controller.canRemoveHelper)
        }
        await client.setState(.stopped)
        await controller.synchronize()
        #expect(controller.canRemoveHelper)
        await client.failRuntime(ServiceFailure.internalError("lost connection"))
        await controller.synchronize()
        #expect(!controller.canRemoveHelper)
    }

    @Test("editing invalidates stale blocking preflight and requires fresh isolation confirmation")
    func editsInvalidatePreflight() async {
        let client = TestSessionClient()
        let running = session()
        await client.setReport(PreflightReport(checks: [], issues: [
            PreflightIssue(id: "old", severity: .error, title: "Old error", message: "Old subnet")
        ], generatedAt: Date()))
        let controller = SessionController(client: client)
        await controller.runPreflight(SessionStartRequest(draft: SessionDraft(
            profileSnapshot: running.profileSnapshot, selectedInterface: running.interfaceSnapshot,
            resolvedSystemDNSServers: [], safetyConfirmation: true
        )))
        controller.isolationConfirmed = true
        #expect(!controller.canStart(profile: running.profileSnapshot, hasInterface: true, helperReady: true))
        controller.configurationChanged()
        #expect(controller.preflightReport == nil)
        #expect(!controller.isolationConfirmed)
        controller.isolationConfirmed = true
        #expect(controller.canStart(profile: running.profileSnapshot, hasInterface: true, helperReady: true))
    }

    @Test("recovery adopts the returned running session")
    func recoveryAdoptsSession() async {
        let client = TestSessionClient()
        let running = session()
        await client.setRecovery(RecoveryReport(outcome: .reattachedToRunningSession, recoveredSession: running))
        let controller = SessionController(client: client)
        await controller.synchronize()
        #expect(controller.activeSession == running)
        #expect(controller.isRunning)
    }

    @Test("polling observes unexpected service failure")
    func statusTracksFailure() async {
        let client = TestSessionClient()
        await client.setState(.running(session()))
        let controller = SessionController(client: client)
        await controller.synchronize()
        let failure = ServiceFailure(code: .processStartFailed, title: "Exited", message: "Engine exited")
        await client.setState(.failed(failure))
        await controller.synchronize()
        #expect(!controller.isRunning)
        #expect(controller.lastFailure == failure)
    }
}
