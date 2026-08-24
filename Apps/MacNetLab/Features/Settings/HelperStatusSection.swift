import MacNetModels
import SwiftUI

/// Settings → Privileged Helper (ticket §5.7), and the place the user is sent whenever the
/// helper needs attention.
struct HelperStatusSection: View {
    @Environment(HelperStatusModel.self) private var model

    /// Uninstall is refused while services are running — ticket §5.7. Passed in rather than
    /// read here so this view has no opinion about where run state lives.
    let isSessionRunning: Bool

    @State private var isConfirmingUninstall = false

    var body: some View {
        Section("Privileged Helper") {
            LabeledContent("Status") {
                statusLabel
            }
            .accessibilityIdentifier("settings.helperStatus")

            if let info = connectedInfo {
                LabeledContent("Helper Version", value: info.helperVersion)
                LabeledContent("Protocol Version", value: "\(info.protocolVersion)")

                if info.isDebugBuild {
                    developmentBuildNotice
                }
            }

            if case .failed(let failure) = model.readiness {
                failureDetail(failure)
            }

            if case .incompatible(_, let reason) = model.readiness {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actionRow
        }
        .confirmationDialog(
            "Remove the privileged helper?",
            isPresented: $isConfirmingUninstall
        ) {
            Button("Remove Helper", role: .destructive) {
                Task { await model.uninstall() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MacNetLab will not be able to start any service until the helper is installed again.")
        }
    }

    // MARK: - Status

    private var connectedInfo: HelperServiceInfoSnapshot? {
        switch model.readiness {
        case .ready(let info): info
        case .incompatible(let info, _): info
        default: nil
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        // Text and symbol together, never colour alone (ticket §5.2, §26.2).
        switch model.readiness {
        case .checking, .connecting:
            Label("Checking…", systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
        case .ready:
            Label("Installed and running", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .incompatible:
            Label("Incompatible", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failed:
            Label("Unavailable", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .notInstalled(let state):
            switch state {
            case .notRegistered:
                Label("Not installed", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            case .requiresApproval:
                Label("Waiting for your approval", systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
            case .bundleIncomplete:
                Label("App bundle is incomplete", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            case .enabled:
                Label("Installed", systemImage: "checkmark.circle")
            case .unknown(let raw):
                Label("Unknown state (\(raw))", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var developmentBuildNotice: some View {
        Label {
            Text("Development build. The helper enforces the same caller verification as a release build.")
        } icon: {
            Image(systemName: "hammer.fill")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func failureDetail(_ failure: ServiceFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(failure.message)
                .font(.callout)
            if let suggestion = failure.recoverySuggestion {
                Text(suggestion)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let details = failure.technicalDetails {
                DisclosureGroup("Technical Details") {
                    Text(details)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionRow: some View {
        HStack {
            switch model.readiness {
            case .notInstalled(.requiresApproval):
                // Ticket §10.2: do not re-register in a loop. Guide, then wait and re-check.
                Button("Open Login Items Settings") {
                    model.openLoginItemsSettings()
                }
                .accessibilityIdentifier("settings.openLoginItems")

                Text("Enable MacNetLab, then return here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .notInstalled(.bundleIncomplete):
                Text("Reinstall MacNetLab from your original download.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .ready:
                Button("Remove Helper…", role: .destructive) {
                    isConfirmingUninstall = true
                }
                .disabled(isSessionRunning)
                .help(isSessionRunning
                      ? Text("Stop the running service before removing the helper.")
                      : Text("Unregister the privileged helper."))
                .accessibilityIdentifier("settings.uninstallHelper")

            default:
                Button(installButtonTitle) {
                    Task { await model.install() }
                }
                .accessibilityIdentifier("settings.installHelper")
            }

            Spacer()

            Button("Refresh") {
                Task { await model.refresh() }
            }
            .accessibilityIdentifier("settings.refreshHelper")
        }
        .disabled(model.isBusy)
    }

    private var installButtonTitle: LocalizedStringKey {
        switch model.readiness {
        case .incompatible, .failed: "Repair Helper"
        default: "Install Helper"
        }
    }
}
