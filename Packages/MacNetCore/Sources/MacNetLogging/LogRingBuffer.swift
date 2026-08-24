import Foundation
import MacNetModels

/// A bounded, append-only buffer of log events.
///
/// ## Why bounded
///
/// A dnsmasq serving a busy DNS cache with query logging on produces lines faster than anyone
/// reads them. Ticket §19.2 and §5.5 cap both ends — 1,000 lines in the helper's reconnect
/// buffer, 5,000 in the app's view — because an unbounded log buffer is a memory leak with a
/// friendly name, and the app is meant to stay under 150 MiB (ticket §25).
///
/// Dropping the oldest is the right eviction: the interesting line is almost always the most
/// recent one, and anything older is still in the log file on disk.
public struct LogRingBuffer: Sendable {

    /// The helper's reconnect buffer (ticket §19.2).
    public static let helperCapacity = 1_000
    /// The app's in-memory view (ticket §5.5).
    public static let appCapacity = 5_000

    public private(set) var events: [LogEvent] = []
    public let capacity: Int

    /// How many events have been dropped to stay within capacity.
    ///
    /// Surfaced rather than silent: a user scrolled to the top should be told the log starts
    /// there because older lines were evicted, not left to assume the service only just began.
    public private(set) var droppedCount = 0

    public init(capacity: Int) {
        // A zero or negative capacity would make `append` drop everything and report nothing,
        // which is a silently useless buffer.
        self.capacity = max(1, capacity)
        events.reserveCapacity(min(self.capacity, 1_024))
    }

    public mutating func append(_ event: LogEvent) {
        events.append(event)
        evictIfNeeded()
    }

    public mutating func append(contentsOf newEvents: [LogEvent]) {
        events.append(contentsOf: newEvents)
        evictIfNeeded()
    }

    private mutating func evictIfNeeded() {
        let excess = events.count - capacity
        guard excess > 0 else { return }
        events.removeFirst(excess)
        droppedCount += excess
    }

    /// Clears the view without touching the underlying file.
    ///
    /// Ticket §5.5 is explicit that Clear View must not truncate the running dnsmasq log: the
    /// file is the record, and a user tidying their screen must not destroy it.
    public mutating func clear() {
        events.removeAll(keepingCapacity: true)
        // `droppedCount` is deliberately not reset: it describes the log, not the view.
    }

    /// The highest sequence number held, or `nil` when empty.
    ///
    /// This is what a reconnecting client sends so it receives exactly what it is missing —
    /// no gaps, no duplicates (ticket §10.3).
    public var highestSequence: Int64? {
        events.last?.sequence
    }

    /// Events after `sequence`.
    public func events(after sequence: Int64) -> [LogEvent] {
        events.filter { $0.sequence > sequence }
    }
}

/// Filters events for the Logs page.
///
/// Kept out of the view so the matching rules are testable, and so the same rules apply to an
/// export as to what is on screen — an export that quietly contained more than the user was
/// looking at would be a surprise in the wrong direction.
public struct LogFilter: Sendable, Equatable {
    public var searchText: String = ""
    /// Categories to show. Empty means all — the natural reading of "no filter applied".
    public var categories: Set<LogCategory> = []

    public init(searchText: String = "", categories: Set<LogCategory> = []) {
        self.searchText = searchText
        self.categories = categories
    }

    public var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !categories.isEmpty
    }

    public func matches(_ event: LogEvent) -> Bool {
        if !categories.isEmpty, !categories.contains(event.category) { return false }

        let needle = searchText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }

        // Case- and diacritic-insensitive: an engineer typing `dhcpack` should find
        // `DHCPACK`, and nobody wants to think about case while chasing a device.
        return event.message.range(
            of: needle, options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    public func apply(to events: [LogEvent]) -> [LogEvent] {
        guard isActive else { return events }
        return events.filter(matches)
    }
}
