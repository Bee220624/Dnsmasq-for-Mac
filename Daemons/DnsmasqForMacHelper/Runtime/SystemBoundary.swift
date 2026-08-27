import Foundation
import MacNetModels

/// The complete set of things the helper does to the machine.
///
/// ## Why every syscall goes through a protocol
///
/// Ticket §24.2 requires the helper's system calls to be injectable, and the reason is not
/// tidiness. The paths that matter most here are the failure paths: an alias that cannot be
/// removed, a port taken between preflight and launch, dnsmasq exiting immediately, a PID that
/// has been recycled. None of those can be produced reliably on a real machine, and all of
/// them must be exercised, because each one is a case where getting it wrong leaves an
/// engineer's Mac in a state they did not ask for.
///
/// Nothing in this file takes a command, a path, or an executable from the caller. Every
/// operation is a named verb with typed arguments (ticket §10.5, §21.1).

// MARK: - Running fixed executables

/// The result of running one of the fixed executables the helper is allowed to invoke.
public struct CommandResult: Sendable, Equatable {
    public let exitStatus: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitStatus: Int32, standardOutput: String, standardError: String) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitStatus == 0 }
}

/// The only executables the helper may run (ticket §21.2).
///
/// An enum rather than a path string. A path parameter would mean "run whatever this names",
/// which is precisely the arbitrary-execution interface the design forbids; a closed set means
/// the question "what can this root process execute?" is answered by reading eight lines.
public enum FixedExecutable: Sendable, Equatable {
    /// `/sbin/ifconfig` — the only way this product changes network configuration.
    case ifconfig
    /// `/usr/sbin/lsof` — diagnostics only. Its failure never changes a decision.
    case lsof
    /// The dnsmasq shipped inside our own bundle, located by the helper from its own path.
    case bundledDnsmasq

    public var path: String {
        switch self {
        case .ifconfig: "/sbin/ifconfig"
        case .lsof: "/usr/sbin/lsof"
        case .bundledDnsmasq: BundledPaths.dnsmasq
        }
    }
}

/// Runs one of the fixed executables with an argument array.
///
/// There is deliberately no way to pass a command string. Ticket §21.1 forbids
/// `/bin/sh -c`, string interpolation into a command, and anything else that would let a
/// value become an instruction.
public protocol CommandRunning: Sendable {
    func run(
        _ executable: FixedExecutable,
        arguments: [String],
        currentDirectory: String?,
        timeout: Duration
    ) async throws -> CommandResult
}

extension CommandRunning {
    public func run(
        _ executable: FixedExecutable,
        arguments: [String]
    ) async throws -> CommandResult {
        try await run(executable, arguments: arguments, currentDirectory: nil, timeout: .seconds(10))
    }
}

// MARK: - Ports

public enum ProbedPort: Sendable, Equatable {
    case dhcpServer      // UDP 67
    case dnsUDP          // UDP 53
    case dnsTCP          // TCP 53

    public var number: UInt16 {
        switch self {
        case .dhcpServer: 67
        case .dnsUDP, .dnsTCP: 53
        }
    }

    public var isTCP: Bool { self == .dnsTCP }
}

public enum PortAvailability: Sendable, Equatable {
    case available
    case inUse
    /// The probe itself could not be performed. Reported separately from "in use" so a broken
    /// probe is never mistaken for a conflict, which would block Start for the wrong reason.
    case indeterminate(String)
}

/// Tests whether a port can be bound.
///
/// Ticket §14.3 requires an actual `bind` rather than parsing `lsof`: only a bind answers the
/// question that matters, which is whether *we* can take the port.
public protocol PortProbing: Sendable {
    func probe(_ port: ProbedPort, boundTo address: IPv4Address) -> PortAvailability
}

// MARK: - Interfaces

/// Adds and removes temporary IPv4 aliases.
public protocol InterfaceAliasManaging: Sendable {
    /// Adds `address` to `interface`. Must be a no-op if the exact address and prefix are
    /// already present (ticket §13.1).
    func addAlias(
        interface: String,
        address: IPv4Address,
        prefixLength: Int
    ) async throws(ServiceFailure)

    /// Removes exactly `address` from `interface`.
    func removeAlias(interface: String, address: IPv4Address) async throws(ServiceFailure)

    /// Brings an interface up. Recorded so a session that did so can put it back down.
    func setInterfaceUp(_ interface: String, up: Bool) async throws(ServiceFailure)
}

// MARK: - Process control

public struct LaunchedProcess: Sendable, Equatable {
    public let processIdentifier: Int32
    public init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }
}

public enum ProcessLiveness: Sendable, Equatable {
    /// Alive, and confirmed to be the executable we launched.
    case runningAsExpected
    /// Alive, but not our process — the PID was recycled. Must never be signalled
    /// (ticket §16.2).
    case identityMismatch(actualPath: String?)
    case notRunning
}

/// Starts, inspects, and stops the dnsmasq process.
public protocol ProcessControlling: Sendable {
    /// Launches the bundled dnsmasq with a fixed argument list and a minimal environment.
    func launchDnsmasq(
        configurationPath: String,
        workingDirectory: String
    ) async throws(ServiceFailure) -> LaunchedProcess

    /// Confirms a PID is both alive and still the process we started.
    func liveness(
        of processIdentifier: Int32,
        expectedExecutableSHA256: String
    ) -> ProcessLiveness

    /// Sends a signal, but only after `liveness` confirms identity.
    func terminate(
        processIdentifier: Int32,
        expectedExecutableSHA256: String,
        gracePeriod: Duration
    ) async throws(ServiceFailure)
}

// MARK: - Runtime files

/// Ownership and permissions for a runtime file (ticket §11).
public struct FileOwnership: Sendable, Equatable {
    public let owner: String
    public let group: String
    public let permissions: UInt16

    public init(owner: String, group: String, permissions: UInt16) {
        self.owner = owner
        self.group = group
        self.permissions = permissions
    }

    /// Files dnsmasq writes after dropping privileges.
    ///
    /// Pre-created with this ownership so the session directory itself can stay unwritable by
    /// the dropped-privilege process: dnsmasq only ever writes into files that already exist.
    public static let dnsmasqWritable = FileOwnership(
        owner: "nobody", group: "nobody", permissions: 0o640
    )

    /// Files only root writes, that dnsmasq must be able to read.
    public static let rootOwnedReadable = FileOwnership(
        owner: "root", group: "wheel", permissions: 0o644
    )

    /// The session directory: root writes, `nobody` traverses and reads.
    public static let sessionDirectory = FileOwnership(
        owner: "root", group: "nobody", permissions: 0o750
    )

    /// The runtime root and the journal.
    public static let privateToRoot = FileOwnership(
        owner: "root", group: "wheel", permissions: 0o600
    )
}

/// Applies owner, group, and mode to a path.
///
/// Separated from `RuntimeFileManaging` because it is the one part that genuinely requires
/// root. Without this seam the file layout could not be tested at all — every write would fail
/// on `chown` — and the layout is where the security-relevant decisions live. A test that
/// substitutes this can assert *what ownership was requested*, which is the fact that matters,
/// rather than whether the running process happened to be privileged.
public protocol OwnershipApplying: Sendable {
    func apply(_ ownership: FileOwnership, to path: String) throws(ServiceFailure)
}

/// Creates and removes the helper's runtime files.
///
/// Takes no path from the caller: everything is derived from the fixed runtime root and a
/// session UUID the helper generated (ticket §21.4).
public protocol RuntimeFileManaging: Sendable {
    func prepareRuntimeRoot() throws(ServiceFailure)
    func createSessionDirectory(sessionID: UUID) throws(ServiceFailure) -> any RuntimePathsProviding
    func write(
        _ contents: String,
        to path: String,
        ownership: FileOwnership
    ) throws(ServiceFailure)
    func createEmptyFile(at path: String, ownership: FileOwnership) throws(ServiceFailure)
    func readFile(at path: String, maximumBytes: Int) throws(ServiceFailure) -> String
    func removeSessionDirectory(sessionID: UUID) throws(ServiceFailure)
    func digest(ofFileAt path: String) throws(ServiceFailure) -> String
}

/// The subset of `RuntimePaths` the helper hands back after creating a session directory.
public protocol RuntimePathsProviding: Sendable {
    var sessionDirectory: String { get }
    var configurationFile: String { get }
    var hostsFile: String { get }
    var leaseFile: String { get }
    var logFile: String { get }
    var pidFile: String { get }
}

// MARK: - Executable verification

public struct ExecutableVerification: Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let version: String
    public let architectures: String
    /// The `Compile time options:` line, retained so Settings can show which features are
    /// actually compiled in rather than which ones the build script asked for.
    public let compileOptions: String

    public init(
        path: String,
        sha256: String,
        version: String,
        architectures: String,
        compileOptions: String = ""
    ) {
        self.path = path
        self.sha256 = sha256
        self.version = version
        self.architectures = architectures
        self.compileOptions = compileOptions
    }
}

/// Verifies the bundled dnsmasq before it is executed as root.
public protocol ExecutableVerifying: Sendable {
    func verifyBundledDnsmasq() async throws(ServiceFailure) -> ExecutableVerification
}

// MARK: - Bundled paths

/// Where the helper finds the things it ships with.
///
/// Derived from the helper's **own** location, never supplied by the app (ticket §21.2). The
/// helper executable sits at `…/Contents/Library/HelperTools/<label>`, so dnsmasq is its
/// sibling — a relationship the app cannot influence.
public enum BundledPaths {
    public static var helperExecutable: String {
        CommandLine.arguments.first.flatMap { argument in
            // Resolve to an absolute, symlink-free path so that a launch through a link
            // cannot move where we look for dnsmasq.
            URL(fileURLWithPath: argument).resolvingSymlinksInPath().path
        } ?? "/"
    }

    public static var helperToolsDirectory: String {
        URL(fileURLWithPath: helperExecutable).deletingLastPathComponent().path
    }

    public static var dnsmasq: String {
        URL(fileURLWithPath: helperToolsDirectory).appending(path: "dnsmasq").path
    }
}
