import Foundation

/// The persisted profile document (ticket §20.2).
///
/// Carries `schemaVersion` so a future format change can be migrated rather than guessed at.
/// A document from a newer version is refused rather than partially understood — silently
/// dropping fields it does not recognise would quietly discard the user's configuration.
public struct ProfileDatabase: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public var defaultProfileID: UUID
    public var profiles: [NetworkProfile]

    public init(schemaVersion: Int = MacNetCoreInfo.schemaVersion,
                defaultProfileID: UUID,
                profiles: [NetworkProfile]) {
        self.schemaVersion = schemaVersion
        self.defaultProfileID = defaultProfileID
        self.profiles = profiles
    }

    /// A first-launch database holding the single default profile (ticket §8).
    public static func initial(now: Date) -> ProfileDatabase {
        let profile = NetworkProfile.makeDefault(now: now)
        return ProfileDatabase(defaultProfileID: profile.id, profiles: [profile])
    }

    public func profile(id: UUID) -> NetworkProfile? {
        profiles.first { $0.id == id }
    }

    /// The profile marked as default, falling back to the first one.
    ///
    /// The fallback exists because `defaultProfileID` and `profiles` are separate fields and a
    /// hand-edited file could disagree. Returning something sensible beats refusing to open.
    public var defaultProfile: NetworkProfile? {
        profile(id: defaultProfileID) ?? profiles.first
    }

    /// Problems that make a decoded document unusable as-is.
    public enum Inconsistency: Sendable, Equatable {
        case noProfiles
        case duplicateProfileIDs
        case defaultProfileMissing
        case unsupportedSchemaVersion(Int)
    }

    /// Checks invariants that `Codable` cannot express.
    ///
    /// Run after decoding, because the file may have been hand-edited, restored from a backup,
    /// or written by a different version. Ticket §5.6 requires at least one profile to exist at
    /// all times, and that is not something the type system enforces.
    public func inconsistencies() -> [Inconsistency] {
        var found: [Inconsistency] = []

        if schemaVersion != MacNetCoreInfo.schemaVersion {
            found.append(.unsupportedSchemaVersion(schemaVersion))
        }
        if profiles.isEmpty {
            found.append(.noProfiles)
        }
        if Set(profiles.map(\.id)).count != profiles.count {
            found.append(.duplicateProfileIDs)
        }
        if !profiles.isEmpty, profile(id: defaultProfileID) == nil {
            found.append(.defaultProfileMissing)
        }
        return found
    }
}
