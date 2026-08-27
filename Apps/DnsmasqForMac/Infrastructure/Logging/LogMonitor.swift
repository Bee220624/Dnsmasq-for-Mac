import Foundation
import MacNetLogging
import MacNetModels
import MacNetXPC
import OSLog
import SwiftUI

/// Supplies the Logs page (ticket §5.5, §19).
///
/// Asks the helper for everything after the highest sequence it already holds, so a reconnect —
/// or a pause and resume — produces no gaps and no duplicates. That is the whole reason the
/// helper stamps sequence numbers rather than timestamps.
@MainActor
@Observable
final class LogMonitor {

    /// Everything held in memory, before filtering. Capped at 5,000 lines (ticket §5.5).
    private(set) var buffer = LogRingBuffer(capacity: LogRingBuffer.appCapacity)

    /// Whether new lines are being appended to the view.
    ///
    /// Pausing stops the *view* updating, not the collection: the helper keeps tailing and the
    /// file keeps growing, so resuming catches up rather than starting a hole.
    private(set) var isPaused = false

    var filter = LogFilter()
    var autoScroll = true

    private let client: HelperClient
    private let logger = Logger(subsystem: "com.bee.dnsmasqformac", category: "log-monitor")

    private var pollTask: Task<Void, Never>?
    private var sessionID: UUID?

    /// Highest sequence received. Survives a pause, so resuming asks for the right thing.
    private var highestSequence: Int64 = 0

    init(client: HelperClient) {
        self.client = client
    }

    // MARK: - Derived

    var visibleEvents: [LogEvent] {
        filter.apply(to: buffer.events)
    }

    var droppedCount: Int { buffer.droppedCount }

    // MARK: - Lifecycle

    func start(sessionID: UUID) {
        guard self.sessionID != sessionID else { return }
        stop()
        self.sessionID = sessionID
        highestSequence = 0

        // 300 ms keeps the log-to-screen latency inside the 500 ms target in ticket §25
        // without making a round trip per line — the helper batches, this drains.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetch()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        sessionID = nil
    }

    /// Clears what is on screen.
    ///
    /// Ticket §5.5 is explicit that this must not truncate the running dnsmasq log: the file is
    /// the record, and a user tidying their screen must not destroy evidence. Only the
    /// in-memory view is emptied; the sequence position is kept so the next fetch continues
    /// rather than replaying everything.
    func clearView() {
        buffer.clear()
    }

    func togglePause() {
        isPaused.toggle()
        // Resuming does not re-request from zero: the helper has been buffering, and
        // `highestSequence` is exactly where to pick up.
        logger.log("logs \(self.isPaused ? "paused" : "resumed", privacy: .public)")
    }

    private func fetch() async {
        guard let sessionID, !isPaused else { return }

        do {
            let batch = try await client.logSnapshot(
                sessionID: sessionID, after: highestSequence
            )
            guard !batch.events.isEmpty else { return }

            buffer.append(contentsOf: batch.events)
            highestSequence = max(highestSequence, batch.highestSequence)
        } catch {
            // Not surfaced: a dropped connection is already reported by the session
            // controller, and a second banner would say the same thing twice.
            logger.debug("log snapshot unavailable: \(error.message, privacy: .public)")
        }
    }

    // MARK: - Export

    /// Renders the log as plain text for export (ticket §5.5).
    ///
    /// Exports **what is on screen**, filter and all. An export that quietly contained more
    /// than the user was looking at would be a surprise in the wrong direction — and this file
    /// is the thing they attach to a ticket.
    func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current

        var lines: [String] = [
            "# Dnsmasq for Mac log export",
            "# Exported \(formatter.string(from: Date()))",
        ]
        if filter.isActive {
            // Stated in the file itself, so nobody later mistakes a filtered export for the
            // whole log.
            lines.append("# Filter applied — this is not the complete log.")
            if !filter.searchText.isEmpty {
                lines.append("# Search: \(filter.searchText)")
            }
            if !filter.categories.isEmpty {
                let names = filter.categories.map(\.displayName).sorted()
                lines.append("# Categories: \(names.joined(separator: ", "))")
            }
        }
        if droppedCount > 0 {
            lines.append("# \(droppedCount) earlier line(s) were dropped from the in-memory buffer.")
            lines.append("# The complete log is on disk in the session directory.")
        }
        lines.append("")

        for event in visibleEvents {
            lines.append(
                "\(formatter.string(from: event.timestamp))\t"
                    + "\(event.category.displayName)\t\(event.message)"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
