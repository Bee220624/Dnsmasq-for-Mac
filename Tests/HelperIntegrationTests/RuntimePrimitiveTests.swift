import Foundation
import Testing
import MacNetDnsmasq
import MacNetModels

/// Coverage for the helper's runtime primitives (ticket §Phase 7).
///
/// These run against a temporary root rather than `/var/db`, so they need no privilege — but
/// they exercise the real implementations, not stand-ins for them.

@Suite("Runtime file manager")
struct RuntimeFileManagerTests {

    private func makeManager() -> (RuntimeFileManager, RecordingOwnershipApplier, String) {
        let root = NSTemporaryDirectory() + "dnsmasqformac-runtime-\(UUID().uuidString)"
        let applier = RecordingOwnershipApplier()
        return (RuntimeFileManager(root: root, ownershipApplier: applier), applier, root)
    }

    private func cleanUp(_ root: String) {
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test("session paths are built from the session UUID alone")
    func sessionPathsUseUUID() throws {
        let (_, _, root) = makeManager()
        defer { cleanUp(root) }

        let sessionID = UUID()
        let paths = RuntimePaths(runtimeRoot: root, sessionID: sessionID)

        // Ticket §21.4: never a profile name, hostname, or interface name — none of which are
        // ours, and any of which could contain a separator.
        #expect(paths.sessionDirectory == "\(root)/sessions/\(sessionID.uuidString)")
        #expect(paths.configurationFile.hasSuffix("/dnsmasq.conf"))
        #expect(paths.leaseFile.hasSuffix("/dnsmasq.leases"))
        #expect(paths.logFile.hasSuffix("/dnsmasq.log"))
        #expect(paths.pidFile.hasSuffix("/dnsmasq.pid"))
    }

    @Test("writes are atomic and readable back")
    func writesAreReadable() throws {
        let (manager, applier, root) = makeManager()
        defer { cleanUp(root) }

        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true
        )
        let path = "\(root)/example.conf"
        let text = "interface=en7\nbind-interfaces\n"
        try manager.write(text, to: path, ownership: .rootOwnedReadable)

        #expect(try manager.readFile(at: path, maximumBytes: 4096) == text)

        // The requested ownership is the security-relevant fact: dnsmasq reads this file after
        // dropping to `nobody`, and it must not be able to write it.
        #expect(applier.ownership(forPathEndingIn: "example.conf")?.owner == "root")
        #expect(applier.ownership(forPathEndingIn: "example.conf")?.permissions == 0o644)

        // No temporary file may survive the rename.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root)
        #expect(!leftovers.contains { $0.contains(".tmp-") }, "leftovers: \(leftovers)")
    }

    @Test("reads are bounded")
    func readsAreBounded() throws {
        let (manager, _, root) = makeManager()
        defer { cleanUp(root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let path = "\(root)/big.log"
        try Data(String(repeating: "x", count: 10_000).utf8)
            .write(to: URL(fileURLWithPath: path))

        // A lease or log file that has grown unexpectedly must not make the root helper
        // allocate without limit (ticket §18.3).
        let text = try manager.readFile(at: path, maximumBytes: 100)
        #expect(text.count == 100)
    }

    @Test("digests a file by streaming it")
    func digestsFile() throws {
        let (manager, _, root) = makeManager()
        defer { cleanUp(root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let path = "\(root)/payload"
        try Data("abc".utf8).write(to: URL(fileURLWithPath: path))

        // SHA-256 of "abc", a published value — so this checks the digest is what everyone
        // else would compute, not merely that it is stable.
        #expect(try manager.digest(ofFileAt: path)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("digesting a missing file reports it rather than returning something")
    func digestOfMissingFileFails() {
        let (manager, _, root) = makeManager()
        defer { cleanUp(root) }

        #expect(throws: ServiceFailure.self) {
            try manager.digest(ofFileAt: "\(root)/does-not-exist")
        }
    }
}

@Suite("Session journal")
struct SessionJournalTests {

    private func makeStore()
        -> (SessionJournalStore, RuntimeFileManager, RecordingOwnershipApplier, String) {
        let root = NSTemporaryDirectory() + "dnsmasqformac-journal-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let applier = RecordingOwnershipApplier()
        let fileManager = RuntimeFileManager(root: root, ownershipApplier: applier)
        return (SessionJournalStore(fileManager: fileManager), fileManager, applier, root)
    }

    private func makeJournal(state: JournalState = .preparing) -> SessionJournal {
        SessionJournal(
            sessionID: UUID(),
            state: state,
            interfaceBSDName: "en7",
            serverIPv4: IPv4Address(rawValue: 0xC0A8_3201),
            prefixLength: 24,
            aliasAddedByApp: false,
            interfaceWasUpBeforeStart: true,
            dnsmasqPID: nil,
            dnsmasqExecutableSHA256: String(repeating: "a", count: 64),
            configurationPath: "/tmp/x/dnsmasq.conf",
            leasePath: "/tmp/x/dnsmasq.leases",
            logPath: "/tmp/x/dnsmasq.log",
            startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("round-trips through disk, private to root")
    func roundTrips() throws {
        let (store, fileManager, applier, root) = makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let journal = makeJournal()
        try store.write(journal, now: Date(timeIntervalSince1970: 1_700_000_100))

        let recovered = try #require(store.read())
        #expect(recovered.sessionID == journal.sessionID)
        #expect(recovered.state == .preparing)
        #expect(recovered.interfaceBSDName == "en7")
        #expect(recovered.serverIPv4.description == "192.168.50.1")
        #expect(recovered.updatedAt == Date(timeIntervalSince1970: 1_700_000_100))

        // The journal records what the helper has done to the machine. Nothing running as a
        // normal user has any business reading or altering it (ticket §11).
        let ownership = applier.ownership(forPathEndingIn: "active-session.json")
        #expect(ownership?.owner == "root")
        #expect(ownership?.group == "wheel")
        #expect(ownership?.permissions == 0o600)
        _ = fileManager
    }

    @Test("no journal reads as no journal")
    func absentJournalIsNil() {
        let (store, _, _, root) = makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(store.read() == nil)
    }

    @Test("an unreadable journal is preserved rather than deleted")
    func unreadableJournalIsPreserved() throws {
        let (store, fileManager, _, root) = makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: fileManager.journalPath))

        #expect(store.read() == nil)
        // It is the only evidence of what the previous session was doing, and a human
        // diagnosing a stuck alias will want it.
        #expect(FileManager.default.fileExists(atPath: "\(fileManager.journalPath).unreadable"))
    }

    @Test("transition records the new state in one step")
    func transitionWrites() throws {
        let (store, _, _, root) = makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let journal = makeJournal()
        try store.write(journal)

        let updated = try store.transition(journal, to: .aliasAdded) { journal in
            journal.aliasAddedByApp = true
        }
        #expect(updated.state == .aliasAdded)
        #expect(updated.aliasAddedByApp)

        // Persisted, not merely returned — that is the whole point of the journal.
        let onDisk = try #require(store.read())
        #expect(onDisk.state == .aliasAdded)
        #expect(onDisk.aliasAddedByApp)
    }

    @Test("states that touched the system require cleanup; the others do not",
          arguments: JournalState.allCases)
    func cleanupRequirementIsCorrect(state: JournalState) {
        let journal = makeJournal(state: state)

        switch state {
        case .preparing:
            // Nothing outside the session directory has been touched.
            #expect(!journal.requiresCleanup)
        case .failed:
            // Already cleaned up; retained only for diagnosis.
            #expect(!journal.requiresCleanup)
        case .aliasAdded, .processStarted, .running, .stopping, .cleanupRequired:
            // An alias, a process, or both exist in the world.
            #expect(journal.requiresCleanup)
        }
    }

    @Test("clearing removes the file")
    func clearRemovesFile() throws {
        let (store, fileManager, _, root) = makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try store.write(makeJournal())
        store.clear()
        #expect(!FileManager.default.fileExists(atPath: fileManager.journalPath))
    }
}

@Suite("Runtime file lock")
struct RuntimeFileLockTests {

    @Test("a second holder is refused rather than made to wait")
    func secondHolderIsRefused() async throws {
        let path = NSTemporaryDirectory() + "dnsmasqformac-lock-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let lock = RuntimeFileLock(path: path)
        let started = AsyncSemaphore()
        let release = AsyncSemaphore()

        let holder = Task {
            try await lock.withLock {
                started.signal()
                await release.wait()
                return true
            }
        }

        await started.wait()

        // A Start that cannot get the lock must say "busy" immediately. Blocking would hang
        // the UI on a lock the user cannot see.
        await #expect(throws: ServiceFailure.self) {
            _ = try await lock.withLock { true }
        }

        release.signal()
        _ = try await holder.value
    }

    @Test("the lock is released after the body finishes")
    func lockIsReleased() async throws {
        let path = NSTemporaryDirectory() + "dnsmasqformac-lock-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let lock = RuntimeFileLock(path: path)
        _ = try await lock.withLock { true }
        // A lock that survived its body would make every later operation fail with "busy".
        _ = try await lock.withLock { true }
    }

    @Test("the lock is released when the body throws")
    func lockIsReleasedOnThrow() async throws {
        let path = NSTemporaryDirectory() + "dnsmasqformac-lock-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let lock = RuntimeFileLock(path: path)
        struct Boom: Error {}

        await #expect(throws: Boom.self) {
            try await lock.withLock { throw Boom() }
        }
        // A failed Start must not poison every subsequent attempt.
        _ = try await lock.withLock { true }
    }
}

/// Minimal one-shot signal, so the lock tests can coordinate without sleeping.
private final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isSignalled = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadySignalled = lock.withLock { () -> Bool in
                if isSignalled { return true }
                waiters.append(continuation)
                return false
            }
            if alreadySignalled { continuation.resume() }
        }
    }
}
