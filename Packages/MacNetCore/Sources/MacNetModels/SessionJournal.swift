import Foundation

/// How far along a session is, from the helper's point of view (ticket §11.1).
///
/// The states exist to answer one question after a crash: *what did we already do that has to
/// be undone?* Each transition is written to disk immediately after the side effect it
/// describes, so a journal found at `aliasAdded` means an alias exists and no process does.
public enum JournalState: String, Codable, Sendable, Equatable, CaseIterable {
    /// Runtime directory and configuration created. Nothing has touched the system yet.
    case preparing
    /// A temporary IPv4 alias has been added to the interface.
    case aliasAdded
    /// dnsmasq has been launched but has not yet been confirmed healthy.
    case processStarted
    /// Fully up.
    case running
    /// A stop is in progress.
    case stopping
    /// Something failed partway. The next start must clean up before doing anything else.
    case cleanupRequired
    /// Terminal failure, retained for diagnosis.
    case failed
}

/// The helper's record of what it has done to the system.
///
/// ## Why a journal rather than in-memory state
///
/// The helper can be killed, the machine can lose power, and the app can crash — at any point
/// between adding an IP alias and starting dnsmasq. Without a durable record of what was
/// already done, recovery would have to guess, and guessing wrong means either leaving an
/// alias on an interface forever or removing an address the user configured themselves.
///
/// Written atomically after every side effect (ticket §11.1), which is what makes the states
/// above trustworthy.
public struct SessionJournal: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public var state: JournalState

    public let interfaceBSDName: String
    public let serverIPv4: IPv4Address
    public let prefixLength: Int

    /// Whether *this app* added the alias.
    ///
    /// The single most important field here. Only an alias recorded as `true` is ever removed;
    /// an address the user configured themselves is never touched, however tempting it looks
    /// during cleanup (ticket §13.2).
    public var aliasAddedByApp: Bool

    /// Whether the interface was already up before the session started, so that a session
    /// which brought it up can put it back down (ticket §15.1 step 10).
    public let interfaceWasUpBeforeStart: Bool

    public var dnsmasqPID: Int32?

    /// Digest of the executable that was launched, so a recycled PID can be told from the
    /// process we started before any signal is sent (ticket §16.2).
    public var dnsmasqExecutableSHA256: String

    public let configurationPath: String
    public let leasePath: String
    public let logPath: String

    public var startedAt: Date?
    public var updatedAt: Date

    public init(
        schemaVersion: Int = MacNetCoreInfo.schemaVersion,
        sessionID: UUID,
        state: JournalState,
        interfaceBSDName: String,
        serverIPv4: IPv4Address,
        prefixLength: Int,
        aliasAddedByApp: Bool,
        interfaceWasUpBeforeStart: Bool,
        dnsmasqPID: Int32?,
        dnsmasqExecutableSHA256: String,
        configurationPath: String,
        leasePath: String,
        logPath: String,
        startedAt: Date?,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.state = state
        self.interfaceBSDName = interfaceBSDName
        self.serverIPv4 = serverIPv4
        self.prefixLength = prefixLength
        self.aliasAddedByApp = aliasAddedByApp
        self.interfaceWasUpBeforeStart = interfaceWasUpBeforeStart
        self.dnsmasqPID = dnsmasqPID
        self.dnsmasqExecutableSHA256 = dnsmasqExecutableSHA256
        self.configurationPath = configurationPath
        self.leasePath = leasePath
        self.logPath = logPath
        self.startedAt = startedAt?.truncatedToSeconds
        self.updatedAt = updatedAt.truncatedToSeconds
    }

    /// Whether a journal in this state describes work that must be undone before anything else
    /// may start.
    public var requiresCleanup: Bool {
        switch state {
        case .preparing, .failed:
            // `preparing` touched nothing outside the session directory; `failed` has already
            // been cleaned up and is kept only for diagnosis.
            false
        case .aliasAdded, .processStarted, .running, .stopping, .cleanupRequired:
            true
        }
    }
}
