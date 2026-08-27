import Darwin
import Foundation
import MacNetModels
import OSLog

/// Reads and writes the session journal (ticket §11.1).
///
/// The journal is what makes recovery possible. Every side effect the helper causes is
/// recorded immediately after it happens, so a helper that starts up and finds a journal knows
/// precisely what exists in the world: an alias, a process, or both. Without it, recovery
/// would have to guess, and both wrong guesses are bad — leaving an alias on an interface
/// forever, or removing an address the user configured themselves.
///
/// Writes are atomic. A journal that is torn halfway through an update is worse than no
/// journal, because it would be trusted.
struct SessionJournalStore: Sendable {

    private let fileManager: RuntimeFileManager
    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "journal")

    init(fileManager: RuntimeFileManager) {
        self.fileManager = fileManager
    }

    // MARK: - Reading

    /// Returns the active journal, or `nil` when there is none.
    ///
    /// A journal that cannot be decoded is treated as absent *and moved aside* rather than
    /// deleted: it is the only evidence of what the previous session was doing, and a human
    /// diagnosing a stuck alias will want it.
    func read() -> SessionJournal? {
        guard FileManager.default.fileExists(atPath: fileManager.journalPath) else { return nil }

        guard let text = try? fileManager.readFile(
            at: fileManager.journalPath, maximumBytes: 256 * 1024
        ) else {
            logger.error("journal could not be read")
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let journal = try? decoder.decode(SessionJournal.self, from: Data(text.utf8)) else {
            logger.fault("journal is unreadable; preserving it for diagnosis")
            preserveUnreadable()
            return nil
        }

        guard journal.schemaVersion == MacNetCoreInfo.schemaVersion else {
            logger.fault("journal schema \(journal.schemaVersion, privacy: .public) is not supported")
            preserveUnreadable()
            return nil
        }
        return journal
    }

    private func preserveUnreadable() {
        let destination = "\(fileManager.journalPath).unreadable"
        try? FileManager.default.removeItem(atPath: destination)
        try? FileManager.default.moveItem(atPath: fileManager.journalPath, toPath: destination)
    }

    // MARK: - Writing

    /// Persists the journal, stamping the update time.
    ///
    /// Called after *every* step with a side effect (ticket §11.1). The cost of an extra write
    /// is nothing next to the cost of not knowing whether an alias exists.
    func write(_ journal: SessionJournal, now: Date = Date()) throws(ServiceFailure) {
        var updated = journal
        updated.updatedAt = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        guard let data = try? encoder.encode(updated),
              let text = String(data: data, encoding: .utf8)
        else {
            throw ServiceFailure.internalError("could not encode the session journal")
        }

        // root:wheel 0600 — this records what the helper has done to the machine, and nothing
        // running as a normal user has any business reading or altering it.
        try fileManager.write(text, to: fileManager.journalPath, ownership: .privateToRoot)
    }

    /// Advances the state and writes, in one step.
    ///
    /// A convenience with a purpose: it makes "change state, then persist" a single call, so
    /// there is no shape of the code where the state was changed in memory and the write was
    /// forgotten.
    @discardableResult
    func transition(
        _ journal: SessionJournal,
        to state: JournalState,
        now: Date = Date(),
        mutate: ((inout SessionJournal) -> Void)? = nil
    ) throws(ServiceFailure) -> SessionJournal {
        var updated = journal
        updated.state = state
        mutate?(&updated)
        try write(updated, now: now)
        logger.log("journal → \(state.rawValue, privacy: .public)")
        return updated
    }

    func clear() {
        guard FileManager.default.fileExists(atPath: fileManager.journalPath) else { return }
        do {
            try FileManager.default.removeItem(atPath: fileManager.journalPath)
            logger.log("journal cleared")
        } catch {
            logger.error("could not clear the journal: \(error)")
        }
    }

    /// Keeps a copy of a journal that could not be acted on safely (ticket §17.3 case D).
    func archiveForDiagnosis(_ journal: SessionJournal, reason: String) {
        let destination = "\(fileManager.journalPath).stale-\(journal.sessionID.uuidString)"
        logger.fault("archiving stale journal: \(reason, privacy: .public)")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? encoder.encode(journal),
           let text = String(data: data, encoding: .utf8) {
            try? fileManager.write(text, to: destination, ownership: .privateToRoot)
        }
    }
}

/// A whole-file advisory lock over `/var/db/com.bee.dnsmasqformac/lock` (ticket §15.1 step 1).
///
/// ## Why a file lock as well as an actor
///
/// The `SessionCoordinator` actor already serialises operations *within* this process. The file
/// lock covers what an actor cannot: a second helper instance. launchd will normally not start
/// one, but "normally" is not a guarantee to bet a root process on, and two helpers racing to
/// add and remove the same alias is exactly the kind of failure that leaves a machine in a
/// state nothing knows how to undo.
///
/// Non-blocking on purpose: a Start that cannot get the lock reports "busy" immediately rather
/// than hanging on a lock the user cannot see.
struct RuntimeFileLock: Sendable {

    private let path: String
    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "lock")

    init(path: String) {
        self.path = path
    }

    /// Runs `body` while holding the lock, or throws if another holder has it.
    ///
    /// The body is `@Sendable` because its only caller is an actor: the closure captures the
    /// actor reference and Sendable request values, then hops back in with `await`. Marking it
    /// is what lets the lock be acquired from inside actor isolation without the closure
    /// smuggling isolated state across the boundary.
    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw ServiceFailure.internalError(
                "could not open \(path): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK {
                throw ServiceFailure(
                    code: .internalError,
                    title: "Another Operation Is In Progress",
                    message: "Dnsmasq for Mac is already starting or stopping a session.",
                    recoverySuggestion: "Wait for the current operation to finish, then try again.",
                    technicalDetails: "the runtime lock is held by another process",
                    isRetryable: true
                )
            }
            throw ServiceFailure.internalError(
                "flock failed: \(String(cString: strerror(code)))"
            )
        }
        defer { flock(descriptor, LOCK_UN) }

        return try await body()
    }
}
