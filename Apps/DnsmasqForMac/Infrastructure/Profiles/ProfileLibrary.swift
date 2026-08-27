import Foundation
import MacNetModels
import OSLog
import SwiftUI

/// The UI's view of the saved profiles, and the draft currently being edited.
///
/// Wraps `ProfileStore` — which is an actor, and correctly so for file work — in something
/// SwiftUI can observe on the main actor. Keeping the two apart means the persistence rules
/// stay testable without a view, and the view never has to think about file layout.
@MainActor
@Observable
final class ProfileLibrary {

    private(set) var profiles: [NetworkProfile] = []
    private(set) var defaultProfileID: UUID?

    /// The profile being edited. Every field on Overview binds into `draft.working`.
    private(set) var draft: ProfileDraft?

    /// Set when profiles had to be recovered, so the UI can say so once. Cleared by
    /// `acknowledgeRecovery()` after the user has seen it.
    private(set) var recoveryNotice: RecoveryNotice?

    /// Set when a save fails. Losing a save silently is worse than any other failure here.
    private(set) var saveFailure: String?

    struct RecoveryNotice: Sendable, Equatable {
        let message: String
        /// Where the damaged file was kept, so the user can be told exactly where to look.
        let salvagePath: String?
    }

    private let store: ProfileStore
    private let logger = Logger(subsystem: "com.bee.dnsmasqformac", category: "profile-library")

    init(store: ProfileStore = ProfileStore()) {
        self.store = store
    }

    var hasUnsavedChanges: Bool { draft?.hasUnsavedChanges ?? false }

    var selectedProfileID: UUID? { draft?.id }

    // MARK: - Loading

    func load() async {
        let outcome = await store.load()
        await syncFromStore()

        // Selecting the default is the only automatic selection this app makes, and it only
        // chooses which settings are *shown* — nothing starts on its own (ticket §0.1).
        if let defaultProfile = profiles.first(where: { $0.id == defaultProfileID })
            ?? profiles.first {
            draft = ProfileDraft(defaultProfile)
        }

        recoveryNotice = Self.notice(for: outcome)
        if let recoveryNotice {
            logger.error("profile recovery: \(recoveryNotice.message, privacy: .public)")
        }
    }

    private static func notice(for outcome: ProfileStore.LoadOutcome) -> RecoveryNotice? {
        switch outcome {
        case .loaded, .createdInitial:
            nil
        case .recoveredFromBackup(let corrupt):
            RecoveryNotice(
                message: "Your profiles could not be read and were restored from the most "
                    + "recent backup. Changes made just before the last save may be missing.",
                salvagePath: corrupt.path
            )
        case .recreatedDefault(let corrupt):
            RecoveryNotice(
                message: "Your profiles could not be read and no usable backup was available, "
                    + "so a new default profile was created.",
                salvagePath: corrupt?.path
            )
        }
    }

    func acknowledgeRecovery() { recoveryNotice = nil }
    func acknowledgeSaveFailure() { saveFailure = nil }

    private func syncFromStore() async {
        let database = await store.database
        profiles = database.profiles.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        defaultProfileID = database.defaultProfileID
    }

    // MARK: - Selection

    /// Switches the edited profile.
    ///
    /// Refuses while there are unsaved changes: the caller must resolve them first via
    /// `resolveUnsavedChanges(_:)`. Ticket §5.3.1 requires a Save / Discard / Cancel prompt,
    /// and returning `false` here is what lets the view present one instead of silently
    /// discarding the user's work.
    @discardableResult
    func select(profileID: UUID) -> Bool {
        guard !hasUnsavedChanges || draft?.id == profileID else { return false }
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return false }

        draft = ProfileDraft(profile)
        return true
    }

    /// Applies the user's answer to the unsaved-changes prompt, then completes the switch.
    func resolveUnsavedChanges(
        _ resolution: UnsavedChangesResolution,
        thenSelect profileID: UUID
    ) async {
        switch resolution {
        case .cancel:
            return
        case .discard:
            draft?.revert()
        case .save:
            await saveDraft()
            // A failed save must not be followed by discarding the work it failed to keep.
            guard saveFailure == nil else { return }
        }
        select(profileID: profileID)
    }

    // MARK: - Editing

    /// A binding into the working copy, for the Overview form fields.
    var workingProfile: Binding<NetworkProfile>? {
        guard draft != nil else { return nil }
        return Binding(
            get: { [weak self] in
                self?.draft?.working ?? NetworkProfile.makeDefault(now: Date())
            },
            set: { [weak self] newValue in self?.draft?.working = newValue }
        )
    }

    func revertDraft() {
        draft?.revert()
    }

    func saveDraft(now: Date = Date()) async {
        guard let draft else { return }

        let profile = draft.profileToSave(now: now)
        do {
            try await store.upsert(profile)
            self.draft?.acceptSaved(profile)
            await syncFromStore()
            saveFailure = nil
        } catch {
            logger.error("could not save profile: \(error)")
            saveFailure = "\(error)"
        }
    }

    // MARK: - Library management

    func createProfile(now: Date = Date()) async {
        let name = ProfileStore.uniqueName(basedOn: "New Profile", existing: profiles.map(\.name))
        var profile = NetworkProfile.makeDefault(now: now)
        profile.name = name

        await perform { store in try await store.upsert(profile) }
        select(profileID: profile.id)
    }

    func duplicate(profileID: UUID, now: Date = Date()) async {
        var copyID: UUID?
        await perform { store in
            copyID = try await store.duplicate(id: profileID, now: now).id
        }
        if let copyID { select(profileID: copyID) }
    }

    func rename(profileID: UUID, to newName: String, now: Date = Date()) async {
        guard var profile = profiles.first(where: { $0.id == profileID }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        profile.name = trimmed
        profile.updatedAt = now
        await perform { store in try await store.upsert(profile) }

        // Keep the draft's baseline in step, so renaming does not read as an unsaved change.
        if draft?.id == profileID {
            draft?.acceptSaved(profile)
        }
    }

    func delete(profileID: UUID) async {
        await perform { store in try await store.delete(id: profileID) }

        if draft?.id == profileID {
            // The running session, if any, holds its own snapshot and is unaffected
            // (ticket §5.6) — this only changes what is being edited.
            draft = profiles.first(where: { $0.id == defaultProfileID })
                .map(ProfileDraft.init)
                ?? profiles.first.map(ProfileDraft.init)
        }
    }

    func setDefault(profileID: UUID) async {
        await perform { store in try await store.setDefault(id: profileID) }
    }

    /// Runs a store mutation, reporting failure rather than letting it vanish.
    private func perform(_ body: (ProfileStore) async throws -> Void) async {
        do {
            try await body(store)
            await syncFromStore()
            saveFailure = nil
        } catch {
            logger.error("profile operation failed: \(error)")
            saveFailure = "\(error)"
        }
    }
}
