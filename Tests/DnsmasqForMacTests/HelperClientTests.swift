import Foundation
import Testing
import MacNetModels
import MacNetXPC

final class TestRegistration: HelperRegistration, @unchecked Sendable {
    private let lock = NSLock()
    private var state: HelperInstallationState = .enabled
    private var removals = 0
    private var registrations = 0
    private var registerError: NSError?
    private var registeredState: HelperInstallationState = .enabled
    func setRegistrationResult(_ value: HelperInstallationState) { lock.withLock { registeredState = value } }
    func failRegistration(_ value: NSError?) { lock.withLock { registerError = value } }
    func setState(_ value: HelperInstallationState) { lock.withLock { state = value } }
    func installationState() -> HelperInstallationState { lock.withLock { state } }
    var removalCount: Int { lock.withLock { removals } }
    var registrationCount: Int { lock.withLock { registrations } }
    func register() throws {
        let failure = lock.withLock {
            registrations += 1
            if registerError == nil { state = registeredState }
            return registerError
        }
        if let failure { throw failure }
    }
    func unregister() async { lock.withLock { removals += 1; state = .notRegistered } }
    func openLoginItemsSettings() {}
}

final class TestHelperProxy: NSObject, DnsmasqForMacHelperProtocol, @unchecked Sendable {
    typealias Reply = @Sendable (Data?, NSError?) -> Void
    private let lock = NSLock()
    private var states: [RuntimeState] = [.stopped]
    private var recovery = RecoveryReport(outcome: .nothingToRecover)
    private var info = HelperServiceInfo(helperVersion: "fixture", protocolVersion: 1,
                                         effectiveUID: 0, buildType: .debug,
                                         bundleIdentifier: "test.helper")
    private var pendingInfo: Reply?
    private var pendingStatus: Reply?
    private var holdInfo = false
    private var holdStatus = false
    private var holdOperation = false
    private var pendingOperation: Reply?
    private var infoFailure: NSError?
    func setInfoFailure(_ value: NSError) { lock.withLock { infoFailure = value } }
    func suspendOperation() { lock.withLock { holdOperation = true } }
    var isOperationPending: Bool { lock.withLock { pendingOperation != nil } }
    func releaseOperation() {
        let reply = lock.withLock { let result = pendingOperation; pendingOperation = nil; holdOperation = false; return result }
        reply?(nil, ServiceFailure.invalidRequest("fixture completed").asNSError)
    }
    private func deferOperation(_ reply: @escaping Reply) -> Bool {
        lock.withLock {
            guard holdOperation else { return false }
            pendingOperation = reply
            return true
        }
    }
    func setStates(_ value: [RuntimeState]) { lock.withLock { states = value } }
    func setRecovery(_ value: RecoveryReport) { lock.withLock { recovery = value } }
    func setInfo(_ value: HelperServiceInfo) { lock.withLock { info = value } }
    func suspendInfo() { lock.withLock { holdInfo = true } }
    func suspendStatus() { lock.withLock { holdStatus = true } }
    var isInfoPending: Bool { lock.withLock { pendingInfo != nil } }
    var isStatusPending: Bool { lock.withLock { pendingStatus != nil } }
    func releaseInfo() {
        let reply = lock.withLock { let result = pendingInfo; pendingInfo = nil; holdInfo = false; return result }
        if let reply { getServiceInfo(withReply: reply) }
    }
    func releaseStatus() {
        let reply = lock.withLock { let result = pendingStatus; pendingStatus = nil; holdStatus = false; return result }
        if let reply { getRuntimeStatus(withReply: reply) }
    }
    private func respond<T: Encodable>(_ value: T, _ reply: Reply) { reply(try! JSONEncoder().encode(value), nil) }
    func getServiceInfo(withReply reply: @escaping Reply) {
        let failure = lock.withLock { let value = infoFailure; infoFailure = nil; return value }
        if let failure { reply(nil, failure); return }
        let value = lock.withLock { () -> HelperServiceInfo? in
            if holdInfo { pendingInfo = reply; return nil }; return info
        }
        if let value { respond(value, reply) }
    }
    func getRuntimeStatus(withReply reply: @escaping Reply) {
        let value = lock.withLock { () -> RuntimeState? in
            if holdStatus { pendingStatus = reply; return nil }
            return states.count > 1 ? states.removeFirst() : states[0]
        }
        if let value { respond(value, reply) }
    }
    func recoverStaleState(withReply reply: @escaping Reply) { respond(lock.withLock { recovery }, reply) }
    func runPreflight(requestData: Data, withReply reply: @escaping Reply) {
        if deferOperation(reply) { return }
        respond(PreflightReport(checks: [], issues: [], generatedAt: Date()), reply)
    }
    func startSession(requestData: Data, withReply reply: @escaping Reply) {
        if deferOperation(reply) { return }
        reply(nil, ServiceFailure.invalidRequest("fixture start reached").asNSError)
    }
    func stopSession(sessionID: String, withReply reply: @escaping Reply) { respond(EmptyHelperReply(), reply) }
    func getLeaseSnapshot(sessionID: String, withReply reply: @escaping Reply) { reply(nil, nil) }
    func getLogSnapshot(sessionID: String, afterSequence: Int64, withReply reply: @escaping Reply) { reply(nil, nil) }
}

func testHelperClient(_ registration: TestRegistration, _ proxy: TestHelperProxy) -> HelperClient {
    HelperClient(environment: AppEnvironment(
        appVersion: "test", buildNumber: "1", bundleIdentifier: "test.app",
        helperLabel: "test.helper", machServiceName: "test.helper", protocolVersion: 1,
        teamIdentifier: nil, operatingSystemVersion: "27", architecture: "arm64"
    ), registration: registration, proxyProvider: { _ in proxy })
}

@Suite("Helper client boundary")
struct HelperClientTests {
    @Test("real handshake rejects wrong UID and protocol", arguments: [(UInt32(501), 1), (UInt32(0), 2)])
    func identity(uid: UInt32, version: Int) async {
        let proxy = TestHelperProxy()
        proxy.setInfo(HelperServiceInfo(helperVersion: "fixture", protocolVersion: version,
                                       effectiveUID: uid, buildType: .debug, bundleIdentifier: "test.helper"))
        let readiness = await testHelperClient(TestRegistration(), proxy).handshake()
        guard case .incompatible = readiness else { Issue.record("untrusted identity became ready"); return }
    }

    @Test("approved registration still requires identity and engine status remains unverified")
    func handshake() async {
        let client = testHelperClient(TestRegistration(), TestHelperProxy())
        guard case .ready(let info) = await client.handshake() else { Issue.record("valid identity refused"); return }
        #expect(info.helperVersion == "fixture")
        #expect(info.engine == nil)
    }

    @Test("registration refusal remains retryable and approval is not readiness")
    func registrationRetry() async {
        let registration = TestRegistration()
        registration.setState(.notRegistered)
        registration.failRegistration(NSError(domain: "SMAppServiceErrorDomain", code: 1))
        let client = testHelperClient(registration, TestHelperProxy())
        do { _ = try await client.install(); Issue.record("registration refusal hidden") }
        catch { #expect(error.code == .helperUnavailable); #expect(error.isRetryable) }
        registration.failRegistration(nil)
        registration.setRegistrationResult(.requiresApproval)
        do { #expect(try await client.install() == .requiresApproval) }
        catch { Issue.record("registration retry failed") }
        #expect(await client.handshake() == .notInstalled(.requiresApproval))
        #expect(registration.registrationCount == 2)
    }

    @Test("failed XPC handshake reports failure and can retry")
    func handshakeRetry() async {
        let proxy = TestHelperProxy()
        proxy.setInfoFailure(NSError(domain: "NSCocoaErrorDomain", code: 4099))
        let client = testHelperClient(TestRegistration(), proxy)
        guard case .failed(let failure) = await client.handshake() else { Issue.record("failure hidden"); return }
        #expect(failure.code == .helperUnavailable)
        guard case .ready = await client.handshake() else { Issue.record("retry failed"); return }
    }

    @Test("pending approval does not register again during refresh") @MainActor
    func approvalDoesNotRegister() async {
        let registration = TestRegistration()
        registration.setState(.requiresApproval)
        let model = HelperStatusModel(client: testHelperClient(registration, TestHelperProxy()))
        await model.refresh()
        await model.refresh()
        #expect(model.readiness == .notInstalled(.requiresApproval))
        #expect(registration.registrationCount == 0)
    }

    @Test("pending session operation blocks removal and registration", arguments: [true, false])
    func sessionBlocksRemoval(start: Bool) async {
        let registration = TestRegistration(), proxy = TestHelperProxy()
        proxy.suspendOperation()
        let client = testHelperClient(registration, proxy)
        let request = request()
        let operation = Task {
            do {
                if start { _ = try await client.startSession(request) }
                else { _ = try await client.preflight(request) }
            } catch {}
        }
        for _ in 0..<1000 { if proxy.isOperationPending { break }; await Task.yield() }
        #expect(proxy.isOperationPending)
        do { try await client.uninstall(); Issue.record("removal overlapped operation") }
        catch { #expect(error.code == .helperUnavailable) }
        do { _ = try await client.install(); Issue.record("registration overlapped operation") }
        catch { #expect(error.code == .helperUnavailable) }
        #expect(registration.removalCount == 0)
        #expect(registration.registrationCount == 0)
        proxy.releaseOperation()
        await operation.value
    }

    private func request() -> SessionStartRequest {
        SessionStartRequest(draft: SessionDraft(
            profileSnapshot: .makeDefault(now: Date()), selectedInterface: NetworkInterfaceDescriptor(
                bsdName: "fixture0", displayName: "Fixture", hardwarePortName: nil, kind: .ethernet,
                macAddress: nil, ipv4Addresses: [], isUp: true, isRunning: true, isLinkActive: true,
                isDefaultRoute: false, isSupported: true, unsupportedReason: nil
            ), resolvedSystemDNSServers: [], safetyConfirmation: false
        ))
    }

    @Test("removal refuses transitioning or failed runtime", arguments: [RuntimeState.starting, .stopping, .recovering,
        .preflighting, .failed(ServiceFailure.internalError("unknown runtime"))])
    func refuseRuntime(_ state: RuntimeState) async {
        let registration = TestRegistration(), proxy = TestHelperProxy()
        proxy.setStates([state])
        do { try await testHelperClient(registration, proxy).uninstall(); Issue.record("unsafe removal succeeded") }
        catch { #expect(registration.removalCount == 0) }
    }

    @Test("removal refuses unresolved recovery", arguments: [RecoveryReport.Outcome.cleanupIncomplete,
        .staleSessionRequiresAttention, .reattachedToRunningSession])
    func refuseRecovery(_ outcome: RecoveryReport.Outcome) async {
        let registration = TestRegistration(), proxy = TestHelperProxy()
        proxy.setRecovery(RecoveryReport(outcome: outcome))
        do { try await testHelperClient(registration, proxy).uninstall(); Issue.record("unresolved removal succeeded") }
        catch { #expect(registration.removalCount == 0) }
    }

    @Test("removal rechecks runtime after cleanup")
    func recheckRuntime() async {
        let registration = TestRegistration(), proxy = TestHelperProxy()
        proxy.setStates([.stopped, .starting])
        do { try await testHelperClient(registration, proxy).uninstall(); Issue.record("changed runtime removed") }
        catch { #expect(registration.removalCount == 0) }
    }

    @Test("confirmed stopped and clean runtime permits removal")
    func cleanRemoval() async throws {
        let registration = TestRegistration()
        try await testHelperClient(registration, TestHelperProxy()).uninstall()
        #expect(registration.removalCount == 1)
    }

    @Test("pending removal blocks registration and preflight across actor reentrancy")
    func overlappingOperations() async throws {
        let registration = TestRegistration(), proxy = TestHelperProxy()
        proxy.suspendStatus()
        let client = testHelperClient(registration, proxy)
        let removal = Task { try await client.uninstall() }
        for _ in 0..<1000 { if proxy.isStatusPending { break }; await Task.yield() }
        // A pre-fix client removes immediately, which itself violates this boundary.
        #expect(proxy.isStatusPending)
        if proxy.isStatusPending {
            do { _ = try await client.install(); Issue.record("registration overlapped removal") } catch {}
            #expect(registration.registrationCount == 0)
            let request = request()
            do { _ = try await client.preflight(request); Issue.record("preflight overlapped removal") }
            catch { #expect(error.code == .helperUnavailable) }
            do { _ = try await client.startSession(request); Issue.record("start overlapped removal") }
            catch { #expect(error.code == .helperUnavailable) }
        }
        proxy.releaseStatus()
        try await removal.value
    }
}

@Suite("Helper status refresh") @MainActor
struct HelperStatusTests {
    @Test("old handshake cannot replace newer approval state")
    func staleRefresh() async {
        let registration = TestRegistration(), proxy = TestHelperProxy()
        proxy.suspendInfo()
        let model = HelperStatusModel(client: testHelperClient(registration, proxy))
        let first = Task { await model.refresh() }
        for _ in 0..<1000 { if proxy.isInfoPending { break }; await Task.yield() }
        #expect(proxy.isInfoPending)
        registration.setState(.requiresApproval)
        await model.refresh()
        proxy.releaseInfo()
        await first.value
        #expect(model.readiness == .notInstalled(.requiresApproval))
        #expect(registration.registrationCount == 0)
    }
}
