import Darwin
import Foundation
import MacNetLogging
import MacNetModels
import MacNetXPC
import OSLog

/// Follows a session's dnsmasq log file and publishes batches of parsed lines (ticket §19.2).
///
/// ## Why the file, not the pipe
///
/// dnsmasq is configured with `log-facility=<session>/dnsmasq.log`, and this reads that file
/// rather than the process's stdout. Ticket §19.1 requires it, and the reason is recovery: a
/// helper that restarts, or one that adopted a dnsmasq it did not spawn, has no pipe — but the
/// file is still there, and the log is still readable from wherever it left off.
///
/// ## What makes tailing a live file awkward
///
/// The file is being appended to while it is read, so a read can land mid-line; it can be
/// rotated out from under the reader; and it can contain bytes that are not valid UTF-8. Each
/// is handled rather than avoided:
///
/// * **Partial lines** are held in a buffer until their newline arrives. Emitting half a line
///   would put a truncated message on screen that never gets corrected.
/// * **Rotation** is detected by inode, not by size — a rotated-then-recreated file can be
///   larger than the offset we hold, so a size comparison would silently skip content.
/// * **Invalid UTF-8** becomes replacement characters. A malformed byte must not cost the user
///   their log.
actor LogFileTailer {

    private let sessionID: UUID
    private let path: String
    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "log-tail")
    private let onBatch: @Sendable (LogBatch) -> Void
    private let clock: @Sendable () -> Date

    private var handle: FileHandle?
    private var watchedInode: UInt64?
    private var offset: UInt64 = 0

    /// Bytes read but not yet terminated by a newline.
    private var partialLine = ""

    /// Monotonic within the session. Never reset, so a reconnecting client's "everything after
    /// N" is always unambiguous (ticket §10.3).
    private var nextSequence: Int64 = 1

    /// Recent history for a client that connects after the fact.
    private var buffer = LogRingBuffer(capacity: LogRingBuffer.helperCapacity)

    private var pollTask: Task<Void, Never>?

    /// Largest single read. A log that has grown unexpectedly must not make the root helper
    /// allocate without limit.
    private static let maximumReadBytes = 1 << 20

    /// Lines per batch (ticket §19.3).
    ///
    /// Batching exists so a busy DNS cache does not mean one XPC round trip per line, which
    /// would cost far more than the logging is worth.
    private static let maximumBatchSize = 100

    init(
        sessionID: UUID,
        path: String,
        clock: @escaping @Sendable () -> Date = { Date() },
        onBatch: @escaping @Sendable (LogBatch) -> Void
    ) {
        self.sessionID = sessionID
        self.path = path
        self.clock = clock
        self.onBatch = onBatch
    }

    // MARK: - Lifecycle

    func start() {
        openFile(fromStart: true)

        // Polled at 100 ms rather than driven by file-system events. dnsmasq with
        // `log-async` writes in bursts, and a poll of a held descriptor is a single cheap
        // `read` returning zero bytes — meaningfully less work than a dispatch source waking
        // for each of a hundred appends. It also keeps the log-to-screen latency inside the
        // 500 ms ticket §25 asks for.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                await self?.pump()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        closeFile()
    }

    /// History for a client that has just connected, or reconnected (ticket §17.1).
    func snapshot(after sequence: Int64) -> LogBatch {
        let events = buffer.events(after: sequence)
        return LogBatch(
            sessionID: sessionID,
            events: events,
            highestSequence: events.last?.sequence ?? sequence
        )
    }

    // MARK: - Reading

    private func openFile(fromStart: Bool) {
        closeFile()

        guard let opened = FileHandle(forReadingAtPath: path) else { return }
        handle = opened
        watchedInode = Self.inode(ofFileAt: path)

        if fromStart {
            offset = 0
        } else {
            // A new file after rotation starts at zero, not at the previous offset.
            offset = 0
            partialLine = ""
        }
        try? opened.seek(toOffset: offset)
    }

    private func closeFile() {
        try? handle?.close()
        handle = nil
        watchedInode = nil
    }

    private func pump() {
        detectRotation()

        guard let handle else {
            // The file may not exist yet; dnsmasq creates it at startup. Retrying costs a
            // failed `open` every 100 ms and nothing else.
            openFile(fromStart: true)
            return
        }

        guard let data = try? handle.read(upToCount: Self.maximumReadBytes), !data.isEmpty else {
            return
        }
        offset += UInt64(data.count)

        // Replacement characters rather than a failure: a read can land mid-character on a
        // file that is being appended to, and losing the log over one byte would not be a
        // trade worth making (ticket §19.2).
        let text = String(decoding: data, as: UTF8.self)
        emit(parseLines(from: text))
    }

    /// Splits incoming text into complete lines, holding any trailing fragment.
    private func parseLines(from text: String) -> [LogEvent] {
        let combined = partialLine + text
        var pieces = combined.components(separatedBy: "\n")

        // The last piece has no newline yet. It is kept rather than emitted, because a
        // truncated message on screen is never corrected once it is there.
        partialLine = pieces.removeLast()

        let now = clock()
        return pieces
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line in
                defer { nextSequence += 1 }
                return LogEvent(
                    sequence: nextSequence,
                    timestamp: now,
                    category: LogClassifier.category(for: line),
                    message: line
                )
            }
    }

    private func emit(_ events: [LogEvent]) {
        guard !events.isEmpty else { return }
        buffer.append(contentsOf: events)

        // Split into batches so one very busy interval does not produce a single enormous
        // payload that would breach the XPC response limit.
        for chunk in stride(from: 0, to: events.count, by: Self.maximumBatchSize) {
            let slice = Array(
                events[chunk..<min(chunk + Self.maximumBatchSize, events.count)]
            )
            guard let highest = slice.last?.sequence else { continue }
            onBatch(LogBatch(sessionID: sessionID, events: slice, highestSequence: highest))
        }
    }

    // MARK: - Rotation

    /// Notices that the path now refers to a different file.
    ///
    /// Compared by inode rather than by size. A rotated-then-recreated log can already be
    /// larger than the offset we hold — dnsmasq writes its startup banner immediately — and a
    /// size comparison would then read from the middle of the new file and silently skip
    /// everything before it.
    private func detectRotation() {
        guard let watchedInode else { return }
        guard let current = Self.inode(ofFileAt: path) else {
            // The file is gone for the moment; rotation is mid-flight. Reopen on the next pump.
            closeFile()
            return
        }
        guard current != watchedInode else { return }

        logger.log("log file was rotated; following the new file")
        // Drain what is left of the old file first, so the last lines before rotation are not
        // lost — they are often the reason the rotation mattered.
        if let handle, let data = try? handle.read(upToCount: Self.maximumReadBytes),
           !data.isEmpty {
            emit(parseLines(from: String(decoding: data, as: UTF8.self)))
        }
        // Any unterminated fragment in the old file will never get its newline.
        flushPartialLine()
        openFile(fromStart: true)
    }

    /// Emits a held fragment that can no longer be completed.
    private func flushPartialLine() {
        let fragment = partialLine.trimmingCharacters(in: .whitespaces)
        partialLine = ""
        guard !fragment.isEmpty else { return }

        emit([LogEvent(
            sequence: nextSequence,
            timestamp: clock(),
            category: LogClassifier.category(for: fragment),
            message: fragment
        )])
        nextSequence += 1
    }

    private static func inode(ofFileAt path: String) -> UInt64? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return UInt64(status.st_ino)
    }
}
