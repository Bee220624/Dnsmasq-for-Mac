import MacNetModels
import MacNetXPC
import SwiftUI

/// Overview — where a session is configured and started (ticket §5.3).
struct OverviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProfileLibrary.self) private var library
    @Environment(InterfaceMonitor.self) private var interfaces
    @Environment(SessionController.self) private var session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let failure = session.lastFailure {
                    FailureBanner(failure: failure) { session.clearFailure() }
                }
                if !session.recoveryWarnings.isEmpty {
                    recoveryBanner
                }

                ProfileCard(isLocked: isLocked)
                InterfaceCard(isLocked: isLocked)

                if let profile = library.draft?.working,
                   session.requiresIsolationConfirmation(for: profile) {
                    SafetyCard(
                        interfaceName: interfaces.selected?.bsdName,
                        poolDescription: poolDescription(profile),
                        isLocked: isLocked
                    )
                }

                PreflightCard(canValidate: canValidate) {
                    Task { await runPreflight() }
                }

                PagePlaceholder(
                    systemImage: "slider.horizontal.3",
                    title: "DHCP and DNS settings",
                    message: "Editable DHCP and DNS forms are added in a later phase. The values from the selected profile are used as-is.",
                    identifier: "overview.pendingCards"
                )
                .frame(minHeight: 120)
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("overview.page")
        // Ticket §5.3.5: a confirmation given about one interface must never carry over to
        // another, and changing the pool changes what "this network" means.
        .onChange(of: interfaces.selectedBSDName) { session.resetIsolationConfirmation() }
        .onChange(of: library.draft?.working.dhcpConfiguration) {
            session.resetIsolationConfirmation()
        }
    }

    // MARK: - State

    /// Configuration is read-only while anything is running or transitioning: the values are
    /// what the running session was started with, and editing them would misrepresent it.
    private var isLocked: Bool {
        session.isRunning || session.isBusy
    }

    private var canValidate: Bool {
        library.draft != nil && interfaces.selected != nil && !session.isRunning
    }

    private func poolDescription(_ profile: NetworkProfile) -> String? {
        guard profile.dhcpConfiguration.enabled else { return nil }
        return "\(profile.dhcpConfiguration.rangeStart) – \(profile.dhcpConfiguration.rangeEnd)"
    }

    // MARK: - Actions

    private func runPreflight() async {
        guard let request = SessionRequestBuilder.make(
            draft: library.draft,
            interface: interfaces.selected,
            isolationConfirmed: session.isolationConfirmed
        ) else { return }
        await session.runPreflight(request)
    }

    @ViewBuilder
    private var recoveryBanner: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("Cleanup After A Previous Session", systemImage: "wrench.and.screwdriver")
                    .font(.headline)
                ForEach(session.recoveryWarnings, id: \.self) { warning in
                    Text(verbatim: warning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Dismiss") { session.acknowledgeRecoveryWarnings() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

/// Builds a start request from what the UI currently has.
///
/// Returns `nil` rather than a partly-filled request when something essential is missing: an
/// incomplete request would be refused by the helper anyway, and a refusal is a worse
/// explanation than a disabled button.
enum SessionRequestBuilder {
    @MainActor
    static func make(
        draft: ProfileDraft?,
        interface: NetworkInterfaceDescriptor?,
        isolationConfirmed: Bool
    ) -> SessionStartRequest? {
        guard let draft, let interface else { return nil }

        return SessionStartRequest(draft: SessionDraft(
            // The *working* copy, not the saved profile: the user pressed Start looking at
            // these values, so these are the values that must run (ticket §5.3.1).
            profileSnapshot: draft.working,
            selectedInterface: interface,
            resolvedSystemDNSServers: SystemResolvers.current(),
            safetyConfirmation: isolationConfirmed
        ))
    }
}

/// Shows a failure with its recovery suggestion and technical detail.
struct FailureBanner: View {
    let failure: ServiceFailure
    let onDismiss: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label(failure.title, systemImage: "exclamationmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)

                Text(verbatim: failure.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if let suggestion = failure.recoverySuggestion {
                    // Often a literal command the user can run — worth selecting and copying.
                    Text(verbatim: suggestion)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let details = failure.technicalDetails, !details.isEmpty {
                    DisclosureGroup("Technical Details") {
                        Text(verbatim: details)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }

                Button("Dismiss", action: onDismiss)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("overview.failureBanner")
    }
}
