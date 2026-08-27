import Darwin
import Foundation
import MacNetLeases
import MacNetModels
import MacNetXPC
import OSLog

/// Watches a session's lease file and publishes snapshots.
///
/// ## Why watch rather than poll
///
/// A lease file changes when a device appears, and then not again for hours. Polling would
/// spend the whole session doing nothing at a fixed cost — the specification targets under 2% CPU
/// while running — and would still be up to a second late. A file-system event is immediate
/// and free when nothing happens.
///
/// The one thing that *is* on a timer is the UI's "time remaining" column, and that ticks from
/// the already-parsed expiry rather than re-reading the file.
///
/// ## Why the file has to be reopened
///
/// dnsmasq rewrites its lease file by replacing it, so the descriptor we are watching stops
/// referring to the file at that path. A watcher that only handled `.write` would go silent
/// after the first lease. `.rename` and `.delete` are therefore watched too, and both reopen.
actor LeaseFileWatcher {

    private let sessionID: UUID
    private let path: String
    private let parser = DnsmasqLeaseParser()
    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "leases")
    private let onSnapshot: @Sendable (LeaseSnapshot) -> Void
    private let clock: @Sendable () -> Date

    private var source: (any DispatchSourceFileSystemObject)?
    private var descriptor: Int32 = -1
    private var debounceTask: Task<Void, Never>?
    private var latest: LeaseSnapshot?

    /// Coalescing window for bursts of writes.
    ///
    /// dnsmasq touches the file several times in quick succession when a lease is granted.
    /// Without this, the app would receive three snapshots for one event; with it, one.
    private static let debounce = Duration.milliseconds(100)

    init(
        sessionID: UUID,
        path: String,
        clock: @escaping @Sendable () -> Date = { Date() },
        onSnapshot: @escaping @Sendable (LeaseSnapshot) -> Void
    ) {
        self.sessionID = sessionID
        self.path = path
        self.clock = clock
        self.onSnapshot = onSnapshot
    }

    // MARK: - Lifecycle

    func start() {
        // Read once immediately. A session that adopts an already-running dnsmasq has leases
        // to show before any file event arrives.
        readAndPublish()
        openWatch()
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        closeWatch()
    }

    /// The most recent snapshot, for a client that has just connected.
    func currentSnapshot() -> LeaseSnapshot {
        latest ?? LeaseSnapshot(
            sessionID: sessionID, leases: [], readAt: clock(), malformedLineCount: 0
        )
    }

    // MARK: - Watching

    private func openWatch() {
        closeWatch()

        descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The file may not exist yet — dnsmasq creates it on the first lease. Retrying
            // rather than failing is what makes an empty pool behave like an empty pool.
            logger.debug("lease file not open yet; will retry")
            scheduleReopen()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            // The event mask is reduced to a plain Bool before crossing into the actor:
            // DispatchSource.FileSystemEvent is not Sendable, and the only thing this needs to
            // know is whether the file was replaced.
            let wasReplaced = source.data.contains(.rename) || source.data.contains(.delete)
            Task { await self.handleEvent(wasReplaced: wasReplaced) }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    private func closeWatch() {
        source?.cancel()      // the cancel handler closes the descriptor
        source = nil
        descriptor = -1
    }

    private func handleEvent(wasReplaced: Bool) {
        // A replaced file needs a new descriptor; the old one still points at the unlinked
        // inode and would never report another event.
        if wasReplaced {
            logger.debug("lease file was replaced; reopening")
            openWatch()
        }
        scheduleRead()
    }

    private func scheduleRead() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.readAndPublish()
        }
    }

    private func scheduleReopen() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            // A second is plenty: this only runs before the first lease exists, and nothing is
            // waiting on it.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.openWatch()
        }
    }

    // MARK: - Reading

    private func readAndPublish() {
        guard let text = readFile() else { return }

        let readAt = clock()
        let result = parser.parse(text, now: readAt)

        if !result.malformedLines.isEmpty {
            // Logged rather than hidden. Some malformed lines are routine — the file is
            // written while it is read — but a persistent count is a real signal.
            logger.debug(
                """
                \(result.malformedLines.count, privacy: .public) unreadable lease line(s); \
                first at line \(result.malformedLines.first?.lineNumber ?? 0, privacy: .public)
                """
            )
        }

        let snapshot = LeaseSnapshot(
            sessionID: sessionID,
            leases: result.leases,
            readAt: readAt,
            malformedLineCount: result.malformedLines.count
        )

        // Publish only on change. The `readAt` timestamp is excluded from the comparison so a
        // re-read that found nothing new does not wake the UI.
        if latest?.leases != snapshot.leases
            || latest?.malformedLineCount != snapshot.malformedLineCount {
            latest = snapshot
            onSnapshot(snapshot)
        } else {
            latest = snapshot
        }
    }

    private func readFile() -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        // Bounded. A pool holds at most 1024 addresses and a lease line is well
        // under 100 bytes, so anything approaching this cap is not a lease file any more.
        let data = (try? handle.read(upToCount: DnsmasqLeaseParser.maximumFileBytes)) ?? Data()

        if data.count >= DnsmasqLeaseParser.maximumFileBytes {
            logger.error("lease file exceeds \(DnsmasqLeaseParser.maximumFileBytes, privacy: .public) bytes; truncated")
        }
        // Replacement characters rather than a failure: a torn multi-byte sequence at the end
        // of a file being written is normal, and losing every lease over it would not be.
        return String(decoding: data, as: UTF8.self)
    }
}
