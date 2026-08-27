import Foundation
import Testing
import MacNetModels
import MacNetXPC

/// Lease watcher coverage (ticket §Phase 9).
///
/// Runs against a real file in a temporary directory, because the behaviour under test *is*
/// file-system behaviour: a file that does not exist yet, a file replaced underneath the
/// watcher, and a torn write.
@Suite("Lease file watcher")
struct LeaseFileWatcherTests {

    private func makePath() -> String {
        let directory = NSTemporaryDirectory() + "dnsmasqformac-leases-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        return "\(directory)/dnsmasq.leases"
    }

    private func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path
        )
    }

    /// Collects snapshots pushed by the watcher.
    private final class SnapshotCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _snapshots: [LeaseSnapshot] = []

        var snapshots: [LeaseSnapshot] { lock.withLock { _snapshots } }

        func record(_ snapshot: LeaseSnapshot) {
            lock.withLock { _snapshots.append(snapshot) }
        }

        /// Waits until a snapshot satisfies `predicate`, or gives up.
        func waitFor(
            timeout: Duration = .seconds(3),
            _ predicate: @escaping ([LeaseSnapshot]) -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if predicate(snapshots) { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return predicate(snapshots)
        }
    }

    @Test("reads an existing lease file on start")
    func readsExistingFile() async throws {
        let path = makePath()
        defer { cleanUp(path) }

        try Data("1787558400 00:11:22:33:44:55 192.168.50.10 bmc01 *\n".utf8)
            .write(to: URL(fileURLWithPath: path))

        let collector = SnapshotCollector()
        let watcher = LeaseFileWatcher(
            sessionID: UUID(), path: path,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        ) { collector.record($0) }

        await watcher.start()
        defer { Task { await watcher.stop() } }

        // A session that adopts an already-running dnsmasq has leases to show before any file
        // event arrives, so the first read must not wait for one.
        let snapshot = await watcher.currentSnapshot()
        #expect(snapshot.leases.count == 1)
        #expect(snapshot.leases.first?.hostname == "bmc01")
    }

    @Test("a missing lease file is an empty snapshot, not a failure")
    func missingFileIsEmpty() async throws {
        let path = makePath()
        defer { cleanUp(path) }

        let watcher = LeaseFileWatcher(
            sessionID: UUID(), path: path,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        ) { _ in }

        await watcher.start()
        defer { Task { await watcher.stop() } }

        // dnsmasq creates the file on the first lease. Before that, an empty pool is exactly
        // what an empty pool looks like.
        let snapshot = await watcher.currentSnapshot()
        #expect(snapshot.leases.isEmpty)
    }

    @Test("notices a lease appearing")
    func noticesNewLease() async throws {
        let path = makePath()
        defer { cleanUp(path) }
        try Data("".utf8).write(to: URL(fileURLWithPath: path))

        let collector = SnapshotCollector()
        let watcher = LeaseFileWatcher(
            sessionID: UUID(), path: path,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        ) { collector.record($0) }

        await watcher.start()
        defer { Task { await watcher.stop() } }

        try Data("1787558400 00:11:22:33:44:55 192.168.50.10 bmc01 *\n".utf8)
            .write(to: URL(fileURLWithPath: path))

        let arrived = await collector.waitFor { snapshots in
            snapshots.contains { $0.leases.count == 1 }
        }
        #expect(arrived, "a new lease should reach the app within seconds")
    }

    @Test("keeps working after the file is replaced")
    func survivesFileReplacement() async throws {
        let path = makePath()
        defer { cleanUp(path) }
        try Data("".utf8).write(to: URL(fileURLWithPath: path))

        let collector = SnapshotCollector()
        let watcher = LeaseFileWatcher(
            sessionID: UUID(), path: path,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        ) { collector.record($0) }

        await watcher.start()
        defer { Task { await watcher.stop() } }

        // dnsmasq rewrites the lease file by replacing it. A watcher that only handled .write
        // would go silent after the very first lease — which is the bug this guards.
        let replacement = path + ".new"
        try Data("1787558400 aa:bb:cc:dd:ee:ff 192.168.50.20 switch01 *\n".utf8)
            .write(to: URL(fileURLWithPath: replacement))
        _ = try FileManager.default.replaceItemAt(
            URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: replacement)
        )

        let noticed = await collector.waitFor { snapshots in
            snapshots.contains { $0.leases.first?.hostname == "switch01" }
        }
        #expect(noticed, "a replaced lease file must still be watched")
    }

    @Test("does not republish when nothing changed")
    func doesNotRepublishUnchangedContent() async throws {
        let path = makePath()
        defer { cleanUp(path) }
        let line = "1787558400 00:11:22:33:44:55 192.168.50.10 bmc01 *\n"
        try Data(line.utf8).write(to: URL(fileURLWithPath: path))

        let collector = SnapshotCollector()
        let watcher = LeaseFileWatcher(
            sessionID: UUID(), path: path,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        ) { collector.record($0) }

        await watcher.start()
        defer { Task { await watcher.stop() } }

        // Touch the file with identical content several times.
        for _ in 0..<3 {
            try Data(line.utf8).write(to: URL(fileURLWithPath: path))
            try? await Task.sleep(for: .milliseconds(150))
        }

        // Waking the UI for a file that says the same thing is pure cost, and the leases table
        // would flicker for no reason.
        #expect(collector.snapshots.count <= 1, "got \(collector.snapshots.count) snapshots")
    }
}
