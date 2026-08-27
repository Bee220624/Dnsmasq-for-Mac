import Foundation
import Testing
import MacNetModels
@testable import MacNetLogging

@Suite("Log ring buffer")
struct LogRingBufferTests {

    private func event(_ sequence: Int64, _ message: String = "line",
                       category: LogCategory = .system) -> LogEvent {
        LogEvent(
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(sequence)),
            category: category,
            message: message
        )
    }

    @Test("keeps events up to capacity")
    func keepsEventsUpToCapacity() {
        var buffer = LogRingBuffer(capacity: 3)
        (1...3).forEach { buffer.append(event(Int64($0))) }

        #expect(buffer.events.count == 3)
        #expect(buffer.droppedCount == 0)
    }

    @Test("drops the oldest when full")
    func dropsOldestWhenFull() {
        var buffer = LogRingBuffer(capacity: 3)
        (1...5).forEach { buffer.append(event(Int64($0))) }

        // The interesting line is almost always the most recent, and anything evicted is still
        // in the log file on disk.
        #expect(buffer.events.map(\.sequence) == [3, 4, 5])
        #expect(buffer.droppedCount == 2)
    }

    @Test("reports how many were dropped")
    func reportsDroppedCount() {
        // Surfaced rather than silent: a user scrolled to the top should know the log starts
        // there because lines were evicted, not assume the service just started.
        var buffer = LogRingBuffer(capacity: 2)
        (1...10).forEach { buffer.append(event(Int64($0))) }
        #expect(buffer.droppedCount == 8)
    }

    @Test("a batch larger than capacity keeps only the newest")
    func handlesOversizedBatch() {
        var buffer = LogRingBuffer(capacity: 3)
        buffer.append(contentsOf: (1...10).map { event(Int64($0)) })

        #expect(buffer.events.map(\.sequence) == [8, 9, 10])
        #expect(buffer.droppedCount == 7)
    }

    @Test("a zero capacity is corrected rather than silently useless")
    func rejectsZeroCapacity() {
        // A buffer that drops everything and reports nothing looks exactly like a service
        // producing no output.
        var buffer = LogRingBuffer(capacity: 0)
        buffer.append(event(1))
        #expect(buffer.events.count == 1)
    }

    @Test("clearing empties the view but keeps the drop count")
    func clearKeepsDropHistory() {
        var buffer = LogRingBuffer(capacity: 2)
        (1...5).forEach { buffer.append(event(Int64($0))) }
        buffer.clear()

        #expect(buffer.events.isEmpty)
        // The count describes the log, not the view — clearing the screen does not un-drop
        // lines that were already lost.
        #expect(buffer.droppedCount == 3)
    }

    @Test("sequence numbers support gap-free reconnection")
    func supportsReconnection() {
        var buffer = LogRingBuffer(capacity: 100)
        (1...10).forEach { buffer.append(event(Int64($0))) }

        // A reconnecting client sends the highest sequence it has and receives exactly what it
        // is missing — no gaps, no duplicates.
        #expect(buffer.highestSequence == 10)
        #expect(buffer.events(after: 7).map(\.sequence) == [8, 9, 10])
        #expect(buffer.events(after: 10).isEmpty)
        #expect(buffer.events(after: 0).count == 10)
    }
}

@Suite("Log filter")
struct LogFilterTests {

    private func event(_ sequence: Int64, _ message: String,
                       _ category: LogCategory) -> LogEvent {
        LogEvent(
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            category: category,
            message: message
        )
    }

    private var sample: [LogEvent] {
        [
            event(1, "DHCPACK(en7) 192.168.50.10 bmc01", .dhcp),
            event(2, "query[A] bmc01.lab.test", .dns),
            event(3, "failed to bind", .error),
            event(4, "started, version 2.93", .system),
        ]
    }

    @Test("no filter shows everything")
    func noFilterShowsEverything() {
        // The natural reading of "no categories selected" is "no filter", not "show nothing".
        #expect(LogFilter().apply(to: sample).count == 4)
        #expect(!LogFilter().isActive)
    }

    @Test("filters by category")
    func filtersByCategory() {
        let filter = LogFilter(categories: [.dhcp, .error])
        #expect(filter.apply(to: sample).map(\.sequence) == [1, 3])
    }

    @Test("searches case-insensitively")
    func searchesCaseInsensitively() {
        // Nobody wants to think about case while chasing a device.
        #expect(LogFilter(searchText: "dhcpack").apply(to: sample).map(\.sequence) == [1])
        #expect(LogFilter(searchText: "BMC01").apply(to: sample).map(\.sequence) == [1, 2])
    }

    @Test("combines search and category")
    func combinesSearchAndCategory() {
        let filter = LogFilter(searchText: "bmc01", categories: [.dns])
        #expect(filter.apply(to: sample).map(\.sequence) == [2])
    }

    @Test("whitespace-only search is not a filter")
    func whitespaceSearchIsNotAFilter() {
        #expect(!LogFilter(searchText: "   ").isActive)
        #expect(LogFilter(searchText: "   ").apply(to: sample).count == 4)
    }
}
