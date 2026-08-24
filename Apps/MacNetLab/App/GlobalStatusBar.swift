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
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 16) {
            statusChip

            Divider().frame(height: 20)

            // Profile and interface become live in their own phases. Showing the fields now
            // with an explicit em dash keeps the layout honest rather than hiding them.
            summaryField(title: "Profile", value: Text(verbatim: "—"))
            summaryField(title: "Interface", value: Text(verbatim: "—"))
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
            Text(appState.runtimePhase.displayName)
                .font(.headline)
        } icon: {
            Image(systemName: appState.runtimePhase.systemImage)
                .foregroundStyle(appState.runtimePhase.tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Service status"))
        .accessibilityValue(Text(appState.runtimePhase.displayName))
        .accessibilityIdentifier("status.phase")
    }

    private var startedAtText: Text {
        guard let startedAt = appState.sessionStartedAt else { return Text(verbatim: "—") }
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
        // Start is gated on preflight and the isolation confirmation, neither of which exists
        // yet. Disabled is the correct and safe Phase 1 state: the ticket forbids ever
        // starting a service automatically or without confirmation.
        Button {
            // Wired to the session coordinator in Phase 8.
        } label: {
            Label("Start", systemImage: "play.fill")
                .frame(minWidth: 64)
        }
        .buttonStyle(.borderedProminent)
        .disabled(true)
        .accessibilityIdentifier("overview.startButton")
        .help(Text("Service control becomes available once the privileged helper is installed."))
    }
}
