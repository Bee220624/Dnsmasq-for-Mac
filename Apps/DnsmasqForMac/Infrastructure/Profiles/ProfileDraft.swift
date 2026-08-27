import Foundation
import MacNetModels

/// An editable copy of a saved profile.
///
/// ## Why editing goes through a draft
///
/// Every field on Overview is a live network configuration. Editing the stored profile
/// directly would mean a half-typed subnet is already saved, and a user experimenting with
/// settings would silently destroy the configuration that was working. So selecting a profile
/// copies it, edits apply to the copy, and nothing is written until the user says so.
///
/// Start uses the **draft**, not the stored profile: the user pressed Start looking at these
/// values, so these are the values that must run. Starting does not save —
/// trying a setting once should not overwrite a preset.
struct ProfileDraft: Sendable, Equatable {

    /// The profile this draft came from, exactly as stored.
    private(set) var original: NetworkProfile

    /// The working copy the UI edits.
    var working: NetworkProfile

    init(_ profile: NetworkProfile) {
        original = profile
        working = profile
    }

    var id: UUID { original.id }

    /// True when the working copy differs from what is stored.
    ///
    /// `updatedAt` is excluded from the comparison: it is bookkeeping written at save time, and
    /// including it would make a draft look modified purely because time passed.
    var hasUnsavedChanges: Bool {
        var comparable = working
        comparable.updatedAt = original.updatedAt
        return comparable != original
    }

    /// Discards edits ("Revert").
    mutating func revert() {
        working = original
    }

    /// Produces the profile to persist, stamping the modification time.
    func profileToSave(now: Date) -> NetworkProfile {
        var saved = working
        saved.updatedAt = now
        return saved
    }

    /// Accepts a save as the new baseline, so the draft stops reporting unsaved changes.
    mutating func acceptSaved(_ profile: NetworkProfile) {
        original = profile
        working = profile
    }
}

/// What to do about unsaved edits when the user switches profiles.
///
/// Modelled explicitly because the wrong default here loses work: the prompt must offer all
/// three, and Cancel must genuinely cancel the switch rather than switching anyway.
enum UnsavedChangesResolution: Sendable, Equatable {
    case save
    case discard
    case cancel
}
