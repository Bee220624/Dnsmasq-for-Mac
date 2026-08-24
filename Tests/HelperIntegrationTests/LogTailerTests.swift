import Foundation
import Testing
import MacNetModels
import MacNetXPC

/// Log tailer coverage (ticket §24.1 "Log Tests", §Phase 10).
///
/// Runs against a real file being appended to, because the behaviour under test *is*
/// file behaviour: a read landing mid-line, a file rotated underneath the reader, and bytes
/// that are not valid UTF-8.
@Suite("Log file tailer")
struct LogFileTailerTests {

    private func makePath() -> String {
        let directory = NSTemporaryDirectory() + "macnetlab-log-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        return "\(directory)/dnsmasq.log"
    }

    private func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path
        )
    }

    private final class BatchCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [LogEvent] = []

        var events: [LogEvent] { lock.withLock { _events } }

        func record(_ batch: LogBatch) {
            lock.withLock { _events.append(contentsOf: batch.events) }
        }

        func waitFor(
            timeout: Duration = .seconds(3),
            _ predicate: @escaping ([LogEvent]) -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if predicate(events) { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return predicate(events)
        }
    }

    private func append(_ text: String, to path: String) throws {
        guard let handle = FileHandle(forWritingAtPath: path) else {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test("delivers appended lines")
    func deliversAppendedLines() async throws {
        let path = makePath()
        defer { cleanUp(path) }
        try Data("".utf8).write(to: URL(fileURLWithPath: path))

        let collector = BatchCollector()
        let tailer = LogFileTailer(
            sessionID: UUID(), path: path,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        ) { collector.record($0) }

        await tailer.start()
        defer { Task { await tailer.stop() } }

        try append("dnsmasq[1]: started, version 2.93\n", to: path)
        try append("dnsmasq-dhcp[1]: DHCPACK(en7) 192.168.50.10 00:11:22:33:44:55\n", to: path)

        let arrived = await collector.waitFor { $0.count >= 2 }
        #expect(arrived)
        #expect(collector.events.first?.category == .system)
        #expect(collector.events.dropFirst().first?.category == .dhcp)
    }

    @Test("holds a partial line until its newline arrives")
    func holdsPartialLines() async throws {
        let path = makePath()
        defer { cleanUp(path) }
        try Data("".utf8).write(to: URL(fileURLWithPath: path))

        let collector = BatchCollector()
        let tailer = LogFileTailer(
            sessionID: UUID(), path: path,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        ) { collector.record($0) }

        await tailer.start()
        defer { Task { await tailer.stop() } }

        // A read landing mid-line is normal on a file being appended to. Emitting the
        // fragment would put a truncated message on screen that is never corrected.
        try append("dnsmasq[1]: DHCPACK(en7) 192.16", to: path)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(collector.events.isEmpty, "a fragment must not be emitted")

        try append("8.50.10 bmc01\n", to: path)

        let completed = await collector.waitFor { $0.count == 1 }
        #expect(completed)
        #expect(collector.events.first?.message.contains("192.168.50.10 bmc01") == true)
    }

    @Test("sequence numbers are contiguous and increasing")
    func sequencesAreContiguous() async throws {
        let path = makePath()
        defer { cleanUp(path) }
        try Data("".utf8).write(to: URL(fileURLWithPath: path))

        let collector = BatchCollector()
        let tailer = LogFileTailer(
            sessionID: UUID(), path: path,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        ) { collector.record($0) }

        await tailer.start()
        defer { Task { await tailer.stop() } }

        for index in 1...20 {
            try append("dnsmasq[1]: line \(index)\n", to: path)
        }

        _ = await collector.waitFor { $0.count >= 20 }
        let sequences = collector.events.map(\.sequence)

        // Contiguity is what makes "everything after N" exact on reconnect: a gap would be
        // indistinguishable from a line that was never delivered.
        #expect(sequences == Array(1...Int64(sequences.count)))
    }

    @Test("a reconnecting client receives exactly what it is missing")
    func snapshotIsGapFree() async throws {
        let path = makePath()
        defer { cleanUp(path) }
        try Data("".utf8).write(to: URL(fileURLWithPath: path))

        let tailer = LogFileTailer(
            sessionID: UUID(), path: path,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        ) { _ in }

        await tailer.start()
        defer { Task { await tailer.stop() } }

        for index in 1...10 {
            try append("dnsmasq[1]: line \(index)\n", to: path)
        }
        try? await Task.sleep(for: .milliseconds(500))

        let all = await tailer.snapshot(after: 0)
        #expect(all.events.count == 10)

        let rest = await tailer.snapshot(after: 6)
        #expect(rest.events.map(\.sequence) == [7, 8, 9, 10])

        // Nothing after the newest is not an error — it is the steady state.
        let none = await tailer.snapshot(after: 10)
        #expect(none.events.isEmpty)
        #expect(none.highestSequence == 10)
    }

    @Test("keeps following after the file is rotated")
    func survivesRotation() async throws {
        let path = makePath()
        defer { cleanUp(path) }
        try Data("".utf8).write(to: URL(fileURLWithPath: path))

        let collector = BatchCollector()
        let tailer = LogFileTailer(
            sessionID: UUID(), path: path,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        ) { collector.record($0) }

        await tailer.start()
        defer { Task { await tailer.stop() } }

        try append("dnsmasq[1]: before rotation\n", to: path)
        _ = await collector.waitFor { $0.contains { $0.message.contains("before rotation") } }

        // Rotate: move the old file aside and create a new one at the same path, which is
        // what the rotator does.
        try FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        try Data("dnsmasq[1]: after rotation\n".utf8).write(to: URL(fileURLWithPath: path))

        let followed = await collector.waitFor {
            $0.contains { $0.message.contains("after rotation") }
        }
        // Detected by inode, not size: a fresh log can already be longer than the old offset,
        // and a size comparison would silently skip its opening lines.
        #expect(followed, "the tailer must follow a rotated log")

        // Sequence numbers keep climbing across the rotation, so a reconnecting client is
        // still exact.
        let sequences = collector.events.map(\.sequence)
        #expect(sequences == sequences.sorted())
        #expect(Set(sequences).count == sequences.count, "no duplicate sequence numbers")
    }

    @Test("invalid UTF-8 does not cost the log")
    func survivesInvalidUTF8() async throws {
        let path = makePath()
        defer { cleanUp(path) }
        try Data("".utf8).write(to: URL(fileURLWithPath: path))

        let collector = BatchCollector()
        let tailer = LogFileTailer(
            sessionID: UUID(), path: path,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        ) { collector.record($0) }

        await tailer.start()
        defer { Task { await tailer.stop() } }

        // A lone continuation byte: not valid UTF-8 on its own.
        var bytes = Data("dnsmasq[1]: DHCPACK(en7) ".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE])
        bytes.append(contentsOf: Data(" bmc01\n".utf8))

        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
        try handle.close()

        let arrived = await collector.waitFor { $0.count == 1 }
        // Replacement characters, not a dropped line. A malformed byte must not cost the user
        // their log (ticket §19.2).
        #expect(arrived)
        #expect(collector.events.first?.category == .dhcp)
    }

    @Test("a missing log file is not a failure")
    func missingFileIsNotAFailure() async throws {
        let path = makePath()
        defer { cleanUp(path) }

        let tailer = LogFileTailer(
            sessionID: UUID(), path: path,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        ) { _ in }

        // dnsmasq creates the file at startup; before that there is simply nothing to read.
        await tailer.start()
        defer { Task { await tailer.stop() } }

        let snapshot = await tailer.snapshot(after: 0)
        #expect(snapshot.events.isEmpty)
    }
}
