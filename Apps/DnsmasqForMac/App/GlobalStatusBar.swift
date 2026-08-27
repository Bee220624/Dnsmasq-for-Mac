import SwiftUI

/// Presentation for a `RuntimeStatePhase`.
///
/// Ticket §5.2 and §26.2 both insist that state is never conveyed by colour alone, so every
/// phase carries a label and an SF Symbol as well as a tint. VoiceOver reads the label.
extension RuntimeStatePhase {
    var displayName: LocalizedStringKey {
        switch self {
        case .stopped: "Stopped"
        case .preflighting: "Preflighting"
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Stopping"
        case .recovering: "Recovering"
        case .failed: "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .stopped: "stop.circle"
        case .preflighting: "checklist"
        case .starting: "play.circle"
        case .running: "checkmark.circle.fill"
        case .stopping: "pause.circle"
        case .recovering: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .stopped: .secondary
        case .preflighting, .starting, .stopping, .recovering: .yellow
        case .running: .green
        case .failed: .red
        }
    }

    /// True while a transition is in flight, when Start/Stop must not be re-entered.
    var isTransitioning: Bool {
        switch self {
        case .preflighting, .starting, .stopping, .recovering: true
        case .stopped, .running, .failed: false
        }
    }
}

/// Always-visible summary strip at the top of the main window (ticket §5.2).
struct GlobalStatusBar: View {
    @Environment(SessionController.self) private var session
    @Environment(ProfileLibrary.self) private var library
    @Environment(InterfaceMonitor.self) private var interfaces
    @Environment(HelperStatusModel.self) private var helper

    var body: some View {
        HStack(spacing: 16) {
            statusChip

            Divider().frame(height: 20)

            // Profile and interface become live in their own phases. Showing the fields now
            // with an explicit em dash keeps the layout honest rather than hiding them.
            summaryField(
                title: "Profile",
                value: Text(verbatim: library.draft?.working.name ?? "—")
            )
            summaryField(
                title: "Interface",
                value: Text(verbatim: interfaces.selected?.bsdName ?? "—")
            )
            summaryField(title: "Started", value: startedAtText)

            Spacer(minLength: 12)

            startStopButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusChip: some View {
        Label {
            Text(session.phase.displayName)
                .font(.headline)
        } icon: {
            Image(systemName: session.phase.systemImage)
                .foregroundStyle(session.phase.tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Service status"))
        .accessibilityValue(Text(session.phase.displayName))
        .accessibilityIdentifier("status.phase")
    }

    private var startedAtText: Text {
        guard let startedAt = session.activeSession?.startedAt else { return Text(verbatim: "—") }
        return Text(startedAt, style: .time)
    }

    private func summaryField(title: LocalizedStringKey, value: Text) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            value
                .font(.callout)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var startStopButton: some View {
        if session.isRunning {
            Button {
                Task { await session.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(minWidth: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(session.isBusy)
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityIdentifier("overview.stopButton")
            .accessibilityValue(Text("Running"))
        } else {
            Button {
                Task { await start() }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(minWidth: 64)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
            .accessibilityIdentifier("overview.startButton")
            .accessibilityValue(Text(canStart ? "Ready" : "Not ready"))
            .help(startHelp)
        }
    }

    /// Whether Start is offered.
    ///
    /// The helper refuses anything unsafe regardless — this only decides whether to present an
    /// action that would certainly fail. Both layers matter (ticket §21.6).
    private var canStart: Bool {
        session.canStart(
            profile: library.draft?.working,
            hasInterface: interfaces.selected != nil,
            helperReady: isHelperReady
        )
    }

    private var isHelperReady: Bool {
        if case .ready = helper.readiness { return true }
        return false
    }

    /// Explains a disabled Start, so the user is never left guessing which of several
    /// preconditions is missing.
    private var startHelp: Text {
        if !isHelperReady {
            return Text("Install the privileged helper in Settings first.")
        }
        if interfaces.selected == nil {
            return Text("Choose a network interface.")
        }
        if let profile = library.draft?.working,
           session.requiresIsolationConfirmation(for: profile),
           !session.isolationConfirmed {
            return Text("Confirm the interface is on an isolated network.")
        }
        if session.preflightReport?.hasBlockingIssues == true {
            return Text("Fix the problems listed under Preflight.")
        }
        return Text("Start the DHCP and DNS service.")
    }

    private func start() async {
        guard let request = SessionRequestBuilder.make(
            draft: library.draft,
            interface: interfaces.selected,
            isolationConfirmed: session.isolationConfirmed
        ) else { return }
        await session.start(request)
    }
}
