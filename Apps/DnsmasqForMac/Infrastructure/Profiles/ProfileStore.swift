import Foundation
import MacNetModels
import OSLog

/// Persists network profiles to disk.
///
/// ## Where this runs
///
/// In the app process, as the logged-in user, and nowhere else. The specification is explicit that
/// the root helper must never write user profiles: a root process writing into a user's
/// Application Support directory is both unnecessary and a way to create files the user cannot
/// then manage.
///
/// ## Why an actor
///
/// Saving is read-modify-write across several files. Two overlapping saves could interleave
/// their temporary files and backups and leave the pair inconsistent. Serialising through an
/// actor makes that impossible rather than unlikely.
actor ProfileStore {

    /// What a load produced, including whether anything had to be recovered — the UI has to
    /// tell the user when their profiles came from a backup.
    enum LoadOutcome: Sendable, Equatable {
        /// The primary file was read normally.
        case loaded
        /// The primary file was unusable; the previous backup was used instead.
        case recoveredFromBackup(corruptFileMovedTo: URL)
        /// Neither file was usable; a fresh default profile was created.
        case recreatedDefault(corruptFileMovedTo: URL?)
        /// No file existed. First launch.
        case createdInitial
    }

    private let logger = Logger(subsystem: "com.bee.dnsmasqformac", category: "profiles")
    private let directory: URL
    private let fileManager: FileManager

    private(set) var database: ProfileDatabase
    private(set) var lastOutcome: LoadOutcome = .createdInitial

    // MARK: - Paths

    private var primaryFile: URL { directory.appending(path: "profiles-v1.json") }
    private var backupDirectory: URL { directory.appending(path: "backups") }
    private var previousBackup: URL {
        backupDirectory.appending(path: "profiles-v1.previous.json")
    }
    private var migrationBackup: URL {
        backupDirectory.appending(path: "profiles-v1.migration.json")
    }

    /// Default location: `~/Library/Application Support/com.bee.dnsmasqformac/`.
    static func defaultDirectory(
        appSupportDirectoryName: String = "com.bee.dnsmasqformac"
    ) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appending(path: "Library/Application Support")
        return base.appending(path: appSupportDirectoryName)
    }

    init(
        directory: URL = ProfileStore.defaultDirectory(),
        fileManager: FileManager = .default,
        now: Date = Date()
    ) {
        self.directory = directory
        self.fileManager = fileManager
        database = ProfileDatabase.initial(now: now)
    }

    // MARK: - Loading

    /// Reads profiles from disk, recovering from a damaged file if necessary.
    @discardableResult
    func load(now: Date = Date()) -> LoadOutcome {
        do {
            try createDirectoriesIfNeeded()
        } catch {
            // An unwritable Application Support directory is not recoverable, but it must not
            // stop the app from running: an in-memory default lets the user work, and saving
            // will report the real problem when they try.
            logger.error("could not create \(self.directory.path, privacy: .public): \(error)")
        }

        guard fileManager.fileExists(atPath: primaryFile.path) else {
            logger.log("no profile database; creating the default profile")
            database = ProfileDatabase.initial(now: now)
            lastOutcome = .createdInitial
            try? writeAtomically(database)
            return lastOutcome
        }

        if let loaded = decodeIfValid(at: primaryFile) {
            database = loaded
            lastOutcome = .loaded
            return lastOutcome
        }

        // The specification: never overwrite the damaged file. It is moved aside, so the
        // user keeps a chance of recovering something from it by hand.
        let quarantined = quarantine(primaryFile, now: now)
        logger.error("primary profile database unusable; moved to \(quarantined?.lastPathComponent ?? "?", privacy: .public)")

        if let recovered = decodeIfValid(at: previousBackup) {
            database = recovered
            lastOutcome = .recoveredFromBackup(corruptFileMovedTo: quarantined ?? previousBackup)
            try? writeAtomically(database)
            return lastOutcome
        }

        logger.error("backup unusable as well; recreating the default profile")
        database = ProfileDatabase.initial(now: now)
        lastOutcome = .recreatedDefault(corruptFileMovedTo: quarantined)
        try? writeAtomically(database)
        return lastOutcome
    }

    /// Decodes a file, returning `nil` if it cannot be read, cannot be decoded, or decodes
    /// into something that violates the document's invariants.
    private func decodeIfValid(at url: URL) -> ProfileDatabase? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ProfileDatabase.self, from: data) else {
            return nil
        }

        // A file that decodes but has no profiles, or names a default that is not there, is
        // just as unusable as one that fails to parse — and more dangerous, because it would
        // otherwise be accepted silently.
        let problems = decoded.inconsistencies()
        guard problems.isEmpty else {
            logger.error("\(url.lastPathComponent, privacy: .public) is inconsistent: \(String(describing: problems), privacy: .public)")
            return nil
        }
        return decoded
    }

    /// Moves a damaged file aside, returning where it went.
    private func quarantine(_ url: URL, now: Date) -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let destination = backupDirectory
            .appending(path: "profiles-v1.corrupt-\(stamp).json")

        do {
            try? fileManager.createDirectory(
                at: backupDirectory, withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: url, to: destination)
            return destination
        } catch {
            logger.error("could not quarantine \(url.lastPathComponent, privacy: .public): \(error)")
            return nil
        }
    }

    // MARK: - Saving

    enum SaveError: Error, Sendable {
        case encodingFailed(String)
        case writeFailed(String)
        /// Written successfully, but reading it back did not reproduce what was saved.
        case verificationFailed
    }

    /// Persists the current database.
    func save() throws {
        try writeAtomically(database)
    }

    /// The write sequence from the specification, in order and for a reason.
    ///
    /// 1. Encode first. If encoding fails nothing on disk has been touched.
    /// 2. Write to a temporary file in the *same directory*, so the later replace is a rename
    ///    within one filesystem and therefore atomic.
    /// 3. `fsync` the temporary file. Without it, a power loss can leave a renamed file whose
    ///    contents never reached the disk — the rename is durable but the data is not.
    /// 4. Copy the current file to the previous-backup slot, so there is always one known-good
    ///    generation behind.
    /// 5. Atomically replace.
    /// 6. Read back and decode, to catch a write that "succeeded" but produced something
    ///    unreadable.
    private func writeAtomically(_ database: ProfileDatabase) throws {
        try createDirectoriesIfNeeded()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let data: Data
        do {
            data = try encoder.encode(database)
        } catch {
            throw SaveError.encodingFailed("\(error)")
        }

        let temporary = directory.appending(path: "profiles-v1.json.tmp-\(UUID().uuidString)")

        do {
            try data.write(to: temporary, options: [.atomic])

            // Force the bytes out before the rename is allowed to make them visible.
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()

            if fileManager.fileExists(atPath: primaryFile.path) {
                if fileManager.fileExists(atPath: previousBackup.path) {
                    try fileManager.removeItem(at: previousBackup)
                }
                try fileManager.copyItem(at: primaryFile, to: previousBackup)
            }

            _ = try fileManager.replaceItemAt(primaryFile, withItemAt: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw SaveError.writeFailed("\(error)")
        }

        guard let verified = decodeIfValid(at: primaryFile), verified == database else {
            throw SaveError.verificationFailed
        }
    }

    private func createDirectoriesIfNeeded() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Mutations

    /// Adds or replaces a profile and saves.
    func upsert(_ profile: NetworkProfile) throws {
        var updated = database
        if let index = updated.profiles.firstIndex(where: { $0.id == profile.id }) {
            updated.profiles[index] = profile
        } else {
            updated.profiles.append(profile)
        }
        database = updated
        try save()
    }

    /// Removes a profile.
    ///
    /// Refuses two cases: removing the last profile, which would leave the app
    /// with nothing to show, and removing the default, which must be reassigned first so that
    /// "default" never dangles.
    enum DeleteRefusal: Error, Sendable, Equatable {
        case wouldRemoveLastProfile
        case isDefaultProfile
        case notFound
    }

    func delete(id: UUID) throws {
        guard database.profile(id: id) != nil else { throw DeleteRefusal.notFound }
        guard database.profiles.count > 1 else { throw DeleteRefusal.wouldRemoveLastProfile }
        guard database.defaultProfileID != id else { throw DeleteRefusal.isDefaultProfile }

        var updated = database
        updated.profiles.removeAll { $0.id == id }
        database = updated
        try save()
    }

    func setDefault(id: UUID) throws {
        guard database.profile(id: id) != nil else { throw DeleteRefusal.notFound }
        var updated = database
        updated.defaultProfileID = id
        database = updated
        try save()
    }

    /// Copies a profile under a new identity and a distinct name.
    func duplicate(id: UUID, now: Date = Date()) throws -> NetworkProfile {
        guard let original = database.profile(id: id) else { throw DeleteRefusal.notFound }

        let copy = NetworkProfile(
            id: UUID(),
            name: Self.uniqueName(basedOn: original.name, existing: database.profiles.map(\.name)),
            interfaceConfiguration: original.interfaceConfiguration,
            dhcpConfiguration: original.dhcpConfiguration,
            dnsConfiguration: Self.reidentifiedRecords(original.dnsConfiguration),
            createdAt: now,
            updatedAt: now
        )
        try upsert(copy)
        return copy
    }

    /// Gives the copy's DNS records fresh identifiers.
    ///
    /// Records are `Identifiable` and their ids drive SwiftUI's table selection. Sharing ids
    /// between two profiles would make selecting a row in one highlight a row in the other.
    private static func reidentifiedRecords(_ dns: DNSConfiguration) -> DNSConfiguration {
        var copy = dns
        copy.records = dns.records.map { record in
            LocalDNSRecord(
                id: UUID(),
                enabled: record.enabled,
                hostname: record.hostname,
                ipv4Address: record.ipv4Address,
                comment: record.comment
            )
        }
        return copy
    }

    /// Produces "Name copy", then "Name copy 2", and so on.
    static func uniqueName(basedOn name: String, existing: [String]) -> String {
        let taken = Set(existing)
        let base = "\(name) copy"
        guard taken.contains(base) else { return base }

        var counter = 2
        while taken.contains("\(base) \(counter)") {
            counter += 1
        }
        return "\(base) \(counter)"
    }
}
