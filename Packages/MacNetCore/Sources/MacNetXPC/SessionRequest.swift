import Foundation
import MacNetModels

/// A request to preflight or start a session, as it crosses XPC.
///
/// Carries its own `protocolVersion` even though the handshake already checked one. The
/// handshake tells the app whether the helper is compatible *now*; this tells the helper what
/// the sender believed when it built this payload. They can differ if the app was updated
/// while a connection was open, and a root process should not act on a payload whose shape it
/// is only assuming.
public struct SessionStartRequest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let draft: SessionDraft

    public init(protocolVersion: Int = MacNetCoreInfo.protocolVersion, draft: SessionDraft) {
        self.protocolVersion = protocolVersion
        self.draft = draft
    }
}

/// What the helper reports about a recovery attempt.
public struct RecoveryReport: Codable, Sendable, Equatable {
    /// What the helper found and what it did about it.
    public enum Outcome: String, Codable, Sendable {
        /// No journal. Nothing to recover.
        case nothingToRecover
        /// A journal pointed at a live, verified dnsmasq; the session was re-adopted.
        case reattachedToRunningSession
        /// The process was gone. Whatever the app had added was cleaned up.
        case cleanedUpAfterDeadProcess
        /// The PID is alive but is not our process. Nothing was signalled.
        case staleSessionRequiresAttention
        /// Cleanup was attempted and did not fully succeed.
        case cleanupIncomplete
    }

    public let outcome: Outcome
    /// Things the user should know but which do not block anything.
    public let warnings: [String]
    /// Set when recovery re-adopted a session that is still running.
    public let recoveredSession: ActiveSession?

    public init(outcome: Outcome, warnings: [String] = [], recoveredSession: ActiveSession? = nil) {
        self.outcome = outcome
        self.warnings = warnings
        self.recoveredSession = recoveredSession
    }
}

/// A batch of log lines, as pushed to the app or returned from a snapshot.
public struct LogBatch: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let events: [LogEvent]
    /// Highest sequence number in this batch, so the app can ask for what comes after it.
    public let highestSequence: Int64

    public init(sessionID: UUID, events: [LogEvent], highestSequence: Int64) {
        self.sessionID = sessionID
        self.events = events
        self.highestSequence = highestSequence
    }
}

/// A lease snapshot, as pushed to the app or returned on request.
public struct LeaseSnapshot: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let leases: [DHCPLease]
    public let readAt: Date
    /// Lines that could not be parsed. Surfaced rather than hidden, because a malformed lease
    /// file is a sign something is wrong that the user may need to know about.
    public let malformedLineCount: Int

    public init(
        sessionID: UUID,
        leases: [DHCPLease],
        readAt: Date,
        malformedLineCount: Int
    ) {
        self.sessionID = sessionID
        self.leases = leases
        self.readAt = readAt
        self.malformedLineCount = malformedLineCount
    }
}

/// Payload for `unexpectedProcessExit`.
public struct UnexpectedExitReport: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let exitStatus: Int32?
    /// The tail of the log, which is where the reason will be if there is one.
    public let recentLogLines: [String]
    /// Whether the temporary alias was successfully removed after the exit.
    public let cleanupSucceeded: Bool
    public let cleanupWarnings: [String]

    public init(
        sessionID: UUID,
        exitStatus: Int32?,
        recentLogLines: [String],
        cleanupSucceeded: Bool,
        cleanupWarnings: [String]
    ) {
        self.sessionID = sessionID
        self.exitStatus = exitStatus
        self.recentLogLines = recentLogLines
        self.cleanupSucceeded = cleanupSucceeded
        self.cleanupWarnings = cleanupWarnings
    }
}
