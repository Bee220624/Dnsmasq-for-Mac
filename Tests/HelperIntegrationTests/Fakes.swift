import Foundation
import MacNetInterfaces
import MacNetModels

/// Test doubles for the helper's system boundary.
///
/// These exist to make the *failure* paths reachable. An alias that cannot be removed, a port
/// taken between preflight and launch, a PID that has been recycled — none of these can be
/// produced on demand against a real machine, and every one of them is a case where getting
/// it wrong leaves an engineer's Mac in a state they did not ask for.

// MARK: - Commands

/// Records what was run and replies from a script.
///
/// Recording the invocations is half the point: several tests assert on the *arguments*,
/// because "never build a command from a string" is only true if the argument array is
/// actually what reaches the process.
final class FakeCommandRunner: CommandRunning, @unchecked Sendable {

    struct Invocation: Equatable {
        let executable: FixedExecutable
        let arguments: [String]
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []
    private var responses: [(FixedExecutable, [String]) -> Result<CommandResult, any Error>?] = []

    /// Default reply when nothing more specific matches.
    var defaultResult = CommandResult(exitStatus: 0, standardOutput: "", standardError: "")

    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    /// Replies with `result` for calls matching `predicate`.
    func stub(
        when predicate: @escaping (FixedExecutable, [String]) -> Bool,
        return result: CommandResult
    ) {
        lock.withLock {
            responses.append { executable, arguments in
                predicate(executable, arguments) ? .success(result) : nil
            }
        }
    }

    /// Fails for calls matching `predicate`.
    func stub(
        when predicate: @escaping (FixedExecutable, [String]) -> Bool,
        throw failure: ServiceFailure
    ) {
        lock.withLock {
            responses.append { executable, arguments in
                predicate(executable, arguments) ? .failure(failure) : nil
            }
        }
    }

    func run(
        _ executable: FixedExecutable,
        arguments: [String],
        currentDirectory: String?,
        timeout: Duration
    ) async throws -> CommandResult {
        let outcome: Result<CommandResult, any Error> = lock.withLock {
            _invocations.append(Invocation(executable: executable, arguments: arguments))
            for response in responses {
                if let matched = response(executable, arguments) { return matched }
            }
            return .success(defaultResult)
        }
        return try outcome.get()
    }
}

// MARK: - Interfaces

/// Serves a scripted interface list, which can change between calls.
///
/// The list being mutable is what lets a test model an adapter being unplugged mid-operation,
/// or an alias that ifconfig claims to have added but that never appears.
final class FakeInterfaceEnumerator: InterfaceEnumerating, @unchecked Sendable {

    private let lock = NSLock()
    private var _interfaces: [NetworkInterfaceDescriptor]
    private var _callCount = 0

    init(_ interfaces: [NetworkInterfaceDescriptor] = []) {
        _interfaces = interfaces
    }

    var callCount: Int { lock.withLock { _callCount } }

    func set(_ interfaces: [NetworkInterfaceDescriptor]) {
        lock.withLock { _interfaces = interfaces }
    }

    /// Replaces the list after `afterCall` enumerations, modelling the world changing
    /// underneath an operation.
    private var mutation: (call: Int, interfaces: [NetworkInterfaceDescriptor])?

    func change(to interfaces: [NetworkInterfaceDescriptor], afterCall: Int) {
        lock.withLock { mutation = (afterCall, interfaces) }
    }

    func enumerateInterfaces() -> [NetworkInterfaceDescriptor] {
        lock.withLock {
            _callCount += 1
            if let mutation, _callCount > mutation.call {
                _interfaces = mutation.interfaces
            }
            return _interfaces
        }
    }
}

/// Builds interface descriptors for tests.
enum TestInterface {

    static func ethernet(
        _ bsdName: String = "en7",
        addresses: [(String, String)] = [],
        linkActive: Bool = true,
        defaultRoute: Bool = false
    ) -> NetworkInterfaceDescriptor {
        make(bsdName, kind: .ethernet, addresses: addresses,
             linkActive: linkActive, defaultRoute: defaultRoute)
    }

    static func wifi(_ bsdName: String = "en0") -> NetworkInterfaceDescriptor {
        make(bsdName, kind: .wifi, addresses: [], linkActive: true, defaultRoute: true)
    }

    static func make(
        _ bsdName: String,
        kind: NetworkInterfaceKind,
        addresses: [(String, String)],
        linkActive: Bool,
        defaultRoute: Bool
    ) -> NetworkInterfaceDescriptor {
        let entries = addresses.compactMap { address, netmask -> InterfaceIPv4Address? in
            guard let parsedAddress = IPv4Address(address),
                  let parsedNetmask = IPv4Address(netmask)
            else { return nil }
            return InterfaceIPv4Address(address: parsedAddress, netmask: parsedNetmask)
        }

        let rejection = InterfaceSupportPolicy.rejection(
            bsdName: bsdName, kind: kind, isDefaultRoute: defaultRoute
        )

        return NetworkInterfaceDescriptor(
            bsdName: bsdName,
            displayName: "Test \(bsdName)",
            hardwarePortName: "Test \(bsdName)",
            kind: kind,
            macAddress: "00:11:22:33:44:55",
            ipv4Addresses: entries,
            isUp: true,
            isRunning: linkActive,
            isLinkActive: linkActive,
            isDefaultRoute: defaultRoute,
            isSupported: rejection == nil,
            unsupportedReason: rejection?.message
        )
    }
}

// MARK: - Ports

/// Reports scripted availability per port, so a conflict can be introduced at an exact moment.
final class FakePortProbe: PortProbing, @unchecked Sendable {

    private let lock = NSLock()
    private var results: [ProbedPort: [PortAvailability]] = [:]
    private var _probeCount = 0

    var probeCount: Int { lock.withLock { _probeCount } }

    /// Sets the answer for every probe of `port`.
    func always(_ availability: PortAvailability, for port: ProbedPort) {
        lock.withLock { results[port] = [availability] }
    }

    /// Sets answers consumed in order — the last one repeats.
    ///
    /// This is how "available at preflight, taken by the time we launch" is modelled, which is
    /// the race ticket §15.1 step 12 exists to catch.
    func sequence(_ availabilities: [PortAvailability], for port: ProbedPort) {
        lock.withLock { results[port] = availabilities }
    }

    func probe(_ port: ProbedPort, boundTo address: IPv4Address) -> PortAvailability {
        lock.withLock {
            _probeCount += 1
            guard var queued = results[port], !queued.isEmpty else { return .available }
            let next = queued.removeFirst()
            // The final entry sticks, so a test only has to describe the transition.
            results[port] = queued.isEmpty ? [next] : queued
            return next
        }
    }
}

// MARK: - Aliases

/// Tracks alias state, and can be told to fail either operation.
final class FakeAliasManager: InterfaceAliasManaging, @unchecked Sendable {

    private let lock = NSLock()
    private(set) var addedAliases: [(interface: String, address: IPv4Address)] = []
    private(set) var removedAliases: [(interface: String, address: IPv4Address)] = []
    private(set) var upCalls: [(interface: String, up: Bool)] = []

    var addFailure: ServiceFailure?
    var removeFailure: ServiceFailure?

    /// True when everything added has also been removed.
    ///
    /// The single most important assertion in the lifecycle tests: an alias left behind is a
    /// Mac holding an address it should not have.
    var isBalanced: Bool {
        lock.withLock {
            let added = Set(addedAliases.map { "\($0.interface)/\($0.address)" })
            let removed = Set(removedAliases.map { "\($0.interface)/\($0.address)" })
            return added.subtracting(removed).isEmpty
        }
    }

    func addAlias(
        interface: String,
        address: IPv4Address,
        prefixLength: Int
    ) async throws(ServiceFailure) {
        if let addFailure { throw addFailure }
        lock.withLock { addedAliases.append((interface, address)) }
    }

    func removeAlias(interface: String, address: IPv4Address) async throws(ServiceFailure) {
        if let removeFailure { throw removeFailure }
        lock.withLock { removedAliases.append((interface, address)) }
    }

    func setInterfaceUp(_ interface: String, up: Bool) async throws(ServiceFailure) {
        lock.withLock { upCalls.append((interface, up)) }
    }
}

// MARK: - Processes

/// A scriptable dnsmasq: it can start, fail to start, exit immediately, or ignore SIGTERM.
final class FakeProcessController: ProcessControlling, @unchecked Sendable {

    private let lock = NSLock()

    var launchFailure: ServiceFailure?
    var pidToReturn: Int32 = 4242

    /// What `liveness` reports. Changing it between calls models a process dying, or a PID
    /// being recycled by something else.
    var livenessResult: ProcessLiveness = .runningAsExpected

    /// Set to fail `terminate`, modelling a process that will not die.
    var terminateFailure: ServiceFailure?

    private(set) var launchCount = 0
    private(set) var terminateCount = 0
    private(set) var lastConfigurationPath: String?

    func launchDnsmasq(
        configurationPath: String,
        workingDirectory: String
    ) async throws(ServiceFailure) -> LaunchedProcess {
        if let launchFailure { throw launchFailure }
        lock.withLock {
            launchCount += 1
            lastConfigurationPath = configurationPath
        }
        return LaunchedProcess(processIdentifier: pidToReturn)
    }

    func liveness(
        of processIdentifier: Int32,
        expectedExecutableSHA256: String
    ) -> ProcessLiveness {
        livenessResult
    }

    func terminate(
        processIdentifier: Int32,
        expectedExecutableSHA256: String,
        gracePeriod: Duration
    ) async throws(ServiceFailure) {
        lock.withLock { terminateCount += 1 }
        if let terminateFailure { throw terminateFailure }
        livenessResult = .notRunning
    }
}

// MARK: - Executable verification

final class FakeExecutableVerifier: ExecutableVerifying, @unchecked Sendable {
    var failure: ServiceFailure?
    var verification = ExecutableVerification(
        path: "/fake/dnsmasq",
        sha256: String(repeating: "a", count: 64),
        version: "2.93",
        architectures: "arm64 x86_64"
    )

    func verifyBundledDnsmasq() async throws(ServiceFailure) -> ExecutableVerification {
        if let failure { throw failure }
        return verification
    }
}

// MARK: - Ownership

/// Records requested ownership instead of calling `chown`.
///
/// The recording is the point: what these tests need to prove is that the lease, log, and pid
/// files are requested as `nobody:nobody 0640` and the journal as `root:wheel 0600`. Whether
/// the *test process* was privileged enough to make that true is irrelevant to whether the
/// code asks for the right thing.
final class RecordingOwnershipApplier: OwnershipApplying, @unchecked Sendable {

    private let lock = NSLock()
    private var _requests: [String: FileOwnership] = [:]

    var failure: ServiceFailure?

    var requests: [String: FileOwnership] { lock.withLock { _requests } }

    /// Finds the ownership requested for the file that ends up at a path.
    ///
    /// `RuntimeFileManager` applies ownership to the temporary file *before* renaming it into
    /// place, so that the file never exists at its final path with the wrong permissions. The
    /// recorded path therefore carries a `.tmp-<uuid>` suffix, which is stripped here — the
    /// question a test is asking is "what will this file be owned as", not "what was the
    /// scratch file called".
    func ownership(forPathEndingIn suffix: String) -> FileOwnership? {
        lock.withLock {
            _requests.first { path, _ in
                let settled = path.range(of: ".tmp-").map { String(path[..<$0.lowerBound]) } ?? path
                return settled.hasSuffix(suffix)
            }?.value
        }
    }

    func apply(_ ownership: FileOwnership, to path: String) throws(ServiceFailure) {
        if let failure { throw failure }
        lock.withLock { _requests[path] = ownership }
    }
}
