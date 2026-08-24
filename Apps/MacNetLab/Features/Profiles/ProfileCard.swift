import MacNetModels
import SwiftUI

/// Overview → Profile (ticket §5.3.1).
///
/// The card that decides which settings the rest of Overview is editing, and the only place
/// those edits get written to disk.
struct ProfileCard: View {
    @Environment(ProfileLibrary.self) private var library

    let isLocked: Bool

    /// The switch the user asked for while there were unsaved edits, held until they answer.
    @State private var pendingSelection: UUID?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    picker
                    if library.hasUnsavedChanges {
                        unsavedBadge
                    }
                }
                actions
            }
            .padding(.vertical, 4)
        } label: {
            Label("Profile", systemImage: "square.stack.3d.up")
                .font(.headline)
        }
        .confirmationDialog(
            "Save changes to this profile?",
            isPresented: Binding(
                get: { pendingSelection != nil },
                set: { if !$0 { pendingSelection = nil } }
            )
        ) {
            // All three options, and Cancel genuinely cancels (ticket §5.3.1). A prompt that
            // quietly discards is worse than no prompt, because the user believes they chose.
            Button("Save") { resolve(.save) }
            Button("Discard Changes", role: .destructive) { resolve(.discard) }
            Button("Cancel", role: .cancel) { resolve(.cancel) }
        } message: {
            Text("This profile has changes that have not been saved.")
        }
    }

    // MARK: - Picker

    private var picker: some View {
        Picker(selection: selectionBinding) {
            ForEach(library.profiles) { profile in
                HStack {
                    Text(verbatim: profile.name)
                    if profile.id == library.defaultProfileID {
                        Image(systemName: "star.fill")
                    }
                }
                .tag(UUID?.some(profile.id))
            }
        } label: {
            Text("Profile")
        }
        .pickerStyle(.menu)
        .disabled(isLocked)
        .accessibilityIdentifier("overview.profilePicker")
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { library.selectedProfileID },
            set: { newValue in
                guard let newValue, newValue != library.selectedProfileID else { return }
                // `select` refuses while there are unsaved edits, which is the signal to ask
                // rather than to overwrite.
                if !library.select(profileID: newValue) {
                    pendingSelection = newValue
                }
            }
        )
    }

    private var unsavedBadge: some View {
        Label("Unsaved Changes", systemImage: "pencil.circle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("overview.unsavedChanges")
    }

    // MARK: - Actions

    private var actions: some View {
        HStack {
            Button("New") {
                Task { await library.createProfile() }
            }
            .accessibilityIdentifier("overview.newProfile")

            Button("Duplicate") {
                guard let id = library.selectedProfileID else { return }
                Task { await library.duplicate(profileID: id) }
            }
            .disabled(library.selectedProfileID == nil)
            .accessibilityIdentifier("overview.duplicateProfile")

            Spacer()

            Button("Revert") {
                library.revertDraft()
            }
            .disabled(!library.hasUnsavedChanges)
            .accessibilityIdentifier("overview.revertProfile")

            Button("Save") {
                Task { await library.saveDraft() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!library.hasUnsavedChanges)
            .accessibilityIdentifier("overview.saveProfile")
        }
        // Editing stays available while running — the user may prepare the next session — but
        // switching which profile is loaded does not, since Overview must keep showing what
        // is actually running.
        .disabled(isLocked)
    }

    private func resolve(_ resolution: UnsavedChangesResolution) {
        guard let target = pendingSelection else { return }
        pendingSelection = nil
        Task { await library.resolveUnsavedChanges(resolution, thenSelect: target) }
    }
}
