import Foundation
import Testing
import MacNetModels

/// Persistence coverage (ticket §24.1 "Profile Tests").
///
/// Profiles are the only user data this product keeps. Losing them is not catastrophic —
/// nothing else depends on them — but it is the kind of loss a user notices immediately and
/// never forgives, so the recovery paths are tested as carefully as the happy one.
@Suite("Profile store")
struct ProfileStoreTests {

    /// A store rooted in a fresh temporary directory, plus a cleanup handle.
    private func makeStore(now: Date = Date(timeIntervalSince1970: 1_700_000_000))
        -> (store: ProfileStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "macnetlab-tests-\(UUID().uuidString)")
        return (ProfileStore(directory: directory, now: now), directory)
    }

    private func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - First launch

    @Test("first launch creates the default profile and writes it")
    func firstLaunchCreatesDefault() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }

        let outcome = await store.load()
        #expect(outcome == .createdInitial)

        let database = await store.database
        #expect(database.profiles.count == 1)
        #expect(database.profiles.first?.name == "Direct Device / BMC")
        #expect(database.defaultProfileID == database.profiles.first?.id)

        // Written immediately, not merely held in memory: a crash before the first save would
        // otherwise lose a profile the user had already started editing.
        let file = directory.appending(path: "profiles-v1.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("reloading returns exactly what was saved")
    func savedProfilesReload() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }
        await store.load()

        var profile = try #require(await store.database.profiles.first)
        profile.name = "Rack 4 BMC"
        try await store.upsert(profile)

        // A second store over the same directory is what an app restart looks like.
        let reopened = ProfileStore(directory: directory)
        await reopened.load()

        let names = await reopened.database.profiles.map(\.name)
        #expect(names == ["Rack 4 BMC"])
    }

    // MARK: - Atomicity

    @Test("a save leaves no temporary files behind")
    func saveCleansUpTemporaries() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }
        await store.load()
        try await store.save()

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!contents.contains { $0.contains(".tmp") }, "found: \(contents)")
    }

    @Test("saving keeps one generation of backup")
    func saveKeepsPreviousGeneration() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }
        await store.load()

        var profile = try #require(await store.database.profiles.first)
        profile.name = "First"
        try await store.upsert(profile)
        profile.name = "Second"
        try await store.upsert(profile)

        // The backup should hold the state before the most recent save, which is what makes
        // recovery from a bad write possible at all.
        let backup = directory.appending(path: "backups/profiles-v1.previous.json")
        #expect(FileManager.default.fileExists(atPath: backup.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: backup)
        let previous = try decoder.decode(ProfileDatabase.self, from: data)
        #expect(previous.profiles.first?.name == "First")
    }

    // MARK: - Corruption recovery

    @Test("a corrupt primary file is recovered from the backup, and is not overwritten")
    func recoversFromBackup() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }
        await store.load()

        var profile = try #require(await store.database.profiles.first)
        profile.name = "Known Good"
        try await store.upsert(profile)
        // A second save moves "Known Good" into the backup slot.
        profile.name = "Also Good"
        try await store.upsert(profile)

        let primary = directory.appending(path: "profiles-v1.json")
        try Data("{ this is not json".utf8).write(to: primary)

        let reopened = ProfileStore(directory: directory)
        let outcome = await reopened.load()

        guard case .recoveredFromBackup(let quarantined) = outcome else {
            Issue.record("expected recovery from backup, got \(outcome)")
            return
        }

        let names = await reopened.database.profiles.map(\.name)
        #expect(names == ["Known Good"])

        // Ticket §20.4 step 1: the damaged file is moved aside, never overwritten. The user
        // keeps a chance of salvaging something from it by hand.
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
        let salvage = try String(contentsOf: quarantined, encoding: .utf8)
        #expect(salvage == "{ this is not json")
    }

    @Test("when both files are unusable, a fresh default is created and the wreckage kept")
    func recreatesDefaultWhenBackupAlsoUnusable() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }
        await store.load()
        try await store.save()

        try Data("garbage".utf8)
            .write(to: directory.appending(path: "profiles-v1.json"))
        try Data("also garbage".utf8)
            .write(to: directory.appending(path: "backups/profiles-v1.previous.json"))

        let reopened = ProfileStore(directory: directory)
        let outcome = await reopened.load()

        guard case .recreatedDefault(let quarantined) = outcome else {
            Issue.record("expected a recreated default, got \(outcome)")
            return
        }
        #expect(await reopened.database.profiles.count == 1)
        #expect(quarantined != nil, "the damaged file should still be recoverable by hand")
    }

    @Test("a file that parses but is internally inconsistent is treated as corrupt")
    func rejectsInconsistentDocument() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }
        await store.load()
        try await store.save()

        // Valid JSON, decodes cleanly, and is unusable: no profiles at all. Accepting this
        // would leave the app with an empty list and no way back.
        let empty = """
        { "schemaVersion": 1,
          "defaultProfileID": "00000000-0000-0000-0000-000000000000",
          "profiles": [] }
        """
        try Data(empty.utf8).write(to: directory.appending(path: "profiles-v1.json"))

        let reopened = ProfileStore(directory: directory)
        let outcome = await reopened.load()

        #expect(outcome != .loaded, "an empty profile list must not be accepted")
        #expect(await reopened.database.profiles.count >= 1)
    }

    @Test("a document from a newer schema version is refused rather than partly understood")
    func rejectsNewerSchema() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }
        await store.load()
        try await store.save()

        let primary = directory.appending(path: "profiles-v1.json")
        let text = try String(contentsOf: primary, encoding: .utf8)
            .replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99")
        try Data(text.utf8).write(to: primary)

        let reopened = ProfileStore(directory: directory)
        let outcome = await reopened.load()

        // Silently dropping fields a newer version added would discard the user's
        // configuration while appearing to work.
        #expect(outcome != .loaded)
    }

    // MARK: - Mutations

    @Test("duplicating produces a distinct profile with a distinct name")
    func duplicateIsIndependent() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }
        await store.load()

        let original = try #require(await store.database.profiles.first)
        let copy = try await store.duplicate(id: original.id)

        #expect(copy.id != original.id)
        #expect(copy.name == "Direct Device / BMC copy")
        #expect(copy.interfaceConfiguration == original.interfaceConfiguration)
        #expect(await store.database.profiles.count == 2)
    }

    @Test("duplicated DNS records get fresh identifiers")
    func duplicateReidentifiesRecords() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }
        await store.load()

        var original = try #require(await store.database.profiles.first)
        let address = try #require(IPv4Address("192.168.50.20"))
        original.dnsConfiguration.records = [
            LocalDNSRecord(hostname: "bmc01", ipv4Address: address)
        ]
        try await store.upsert(original)

        let copy = try await store.duplicate(id: original.id)

        // Record ids drive table selection in SwiftUI. Sharing them between two profiles would
        // make selecting a row in one highlight a row in the other.
        let originalIDs = Set(original.dnsConfiguration.records.map(\.id))
        let copyIDs = Set(copy.dnsConfiguration.records.map(\.id))
        #expect(originalIDs.isDisjoint(with: copyIDs))
        #expect(copy.dnsConfiguration.records.map(\.hostname)
            == original.dnsConfiguration.records.map(\.hostname))
    }

    @Test("duplicate names do not collide as copies accumulate")
    func duplicateNamesAreUnique() {
        #expect(ProfileStore.uniqueName(basedOn: "Lab", existing: []) == "Lab copy")
        #expect(ProfileStore.uniqueName(basedOn: "Lab", existing: ["Lab copy"]) == "Lab copy 2")
        #expect(ProfileStore.uniqueName(
            basedOn: "Lab", existing: ["Lab copy", "Lab copy 2"]
        ) == "Lab copy 3")
    }

    @Test("the last remaining profile cannot be deleted")
    func cannotDeleteLastProfile() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }
        await store.load()

        let only = try #require(await store.database.profiles.first)
        // Ticket §5.6: at least one profile must always exist, or the app has nothing to show.
        await #expect(throws: ProfileStore.DeleteRefusal.wouldRemoveLastProfile) {
            try await store.delete(id: only.id)
        }
    }

    @Test("the default profile cannot be deleted until another is made default")
    func cannotDeleteDefaultProfile() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }
        await store.load()

        let original = try #require(await store.database.profiles.first)
        let copy = try await store.duplicate(id: original.id)

        await #expect(throws: ProfileStore.DeleteRefusal.isDefaultProfile) {
            try await store.delete(id: original.id)
        }

        // Reassigning default first is the supported path, and then deletion works.
        try await store.setDefault(id: copy.id)
        try await store.delete(id: original.id)

        #expect(await store.database.profiles.count == 1)
        #expect(await store.database.defaultProfileID == copy.id)
    }

    @Test("deleting an unknown profile is refused rather than silently ignored")
    func deletingUnknownIsRefused() async throws {
        let (store, directory) = makeStore()
        defer { remove(directory) }
        await store.load()

        await #expect(throws: ProfileStore.DeleteRefusal.notFound) {
            try await store.delete(id: UUID())
        }
    }
}

@Suite("Profile draft")
struct ProfileDraftTests {

    private func makeProfile() -> NetworkProfile {
        NetworkProfile.makeDefault(now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("a fresh draft reports no unsaved changes")
    func freshDraftIsClean() {
        #expect(!ProfileDraft(makeProfile()).hasUnsavedChanges)
    }

    @Test("editing the working copy marks the draft as modified")
    func editingMarksModified() {
        var draft = ProfileDraft(makeProfile())
        draft.working.name = "Rack 4"
        #expect(draft.hasUnsavedChanges)
    }

    @Test("editing the draft does not touch the original")
    func editingLeavesOriginalAlone() {
        // The point of the draft: a half-typed subnet must not already be the saved profile.
        var draft = ProfileDraft(makeProfile())
        let before = draft.original

        draft.working.dhcpConfiguration.enabled = false
        draft.working.interfaceConfiguration.prefixLength = 30

        #expect(draft.original == before)
    }

    @Test("reverting restores the stored values")
    func revertRestores() {
        var draft = ProfileDraft(makeProfile())
        draft.working.name = "Changed"
        draft.working.dnsConfiguration.localDomain = "other.test"

        draft.revert()

        #expect(!draft.hasUnsavedChanges)
        #expect(draft.working == draft.original)
    }

    @Test("a modification timestamp alone does not count as an unsaved change")
    func timestampAloneIsNotAChange() {
        // Otherwise every draft would look modified the moment any code stamped it, and the
        // "Unsaved Changes" indicator would stop meaning anything.
        var draft = ProfileDraft(makeProfile())
        draft.working.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!draft.hasUnsavedChanges)
    }

    @Test("saving stamps the modification time to whole seconds")
    func saveStampsWholeSeconds() {
        let draft = ProfileDraft(makeProfile())
        let now = Date(timeIntervalSince1970: 1_700_000_123.987)

        let saved = draft.profileToSave(now: now)

        // Sub-second precision cannot survive ISO-8601, and an unrepresentable value makes the
        // store's read-back verification fail on every successful save.
        #expect(saved.updatedAt == Date(timeIntervalSince1970: 1_700_000_123))
        #expect(saved.createdAt == draft.original.createdAt)
    }

    @Test("accepting a save clears the modified state")
    func acceptingSaveClearsModified() {
        var draft = ProfileDraft(makeProfile())
        draft.working.name = "Rack 4"
        #expect(draft.hasUnsavedChanges)

        let saved = draft.profileToSave(now: Date(timeIntervalSince1970: 1_700_000_500))
        draft.acceptSaved(saved)

        #expect(!draft.hasUnsavedChanges)
        #expect(draft.original.name == "Rack 4")
    }
}
