import SwiftUI

private struct ConnectionReducedMotionPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var connectionReducedMotionPreview: Bool {
        get { self[ConnectionReducedMotionPreviewKey.self] }
        set { self[ConnectionReducedMotionPreviewKey.self] = newValue }
    }
}

/// The production connection scene also accepts a fixed clock for deterministic previews.
struct ConnectionExperience<Action: View>: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.connectionReducedMotionPreview) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    @Environment(\.scenePhase) private var scenePhase
    @State private var clockSettled = false
    let journey: ConnectionJourney
    var snapshotDate: Date? = nil
    var isPaused = false
    var summary = ""
    var titleOverride: LocalizedStringKey? = nil
    var hintOverride: LocalizedStringKey? = nil
    var statusValue: LocalizedStringKey? = nil
    @ViewBuilder var action: (ConnectionJourneyFrame, Date) -> Action

    var body: some View {
        Group {
            if let snapshotDate {
                panel(at: snapshotDate)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60,
                                        paused: isPaused || scenePhase != .active || clockSettled)) { timeline in
                    panel(at: timeline.date)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
        .environment(\.colorScheme, .light)
        .transaction { if snapshotDate != nil { $0.disablesAnimations = true } }
    }

    private func panel(at date: Date) -> some View {
        let frame = journey.frame(at: date)
        return VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text(titleOverride ?? title(for: frame))
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(ConnectionPalette.ink)
                    .contentTransition(.opacity)
                    .accessibilityLabel(Text("Service status"))
                    .accessibilityValue(Text(statusValue ?? LocalizedStringKey(frame.phase.rawValue.capitalized)))
                    .accessibilityIdentifier("status.phase")
                Text(hintOverride ?? hint(for: frame))
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.55, green: 0.59, blue: 0.65))
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .contain)
            .animation(ConnectionMotion.fade, value: frame.phase)
            .padding(.top, 34)

            ConnectionDiagram(frame: frame, date: date)
                .frame(maxWidth: 660)

            action(frame, date)
                .accessibilityElement(children: .contain)
                .padding(.top, 2)

            Text(verbatim: summary)
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.66, green: 0.69, blue: 0.74))
                .padding(.top, 18)
                .frame(height: 32, alignment: .top)
        }
        .padding(.bottom, 32)
        .onChange(of: frame.phase, initial: true) {
            clockSettled = frame.isTerminal || (reduceMotion && frame.phase == .idle)
        }
        .onChange(of: reduceMotion) {
            clockSettled = frame.isTerminal || (reduceMotion && frame.phase == .idle)
        }
    }

    private func title(for frame: ConnectionJourneyFrame) -> LocalizedStringKey {
        switch frame.phase {
        case .idle: "Ready to connect"
        case .pressing, .charging, .flying, .arriving: "Connecting…"
        case .connected: "Connection successful"
        case .failing, .failed: "Connection failed"
        }
    }

    private func hint(for frame: ConnectionJourneyFrame) -> LocalizedStringKey {
        switch frame.phase {
        case .idle: "Your Mac and server, one connection away."
        case .pressing, .charging: "Establishing a local connection."
        case .flying, .arriving: "Connecting your local network…"
        case .connected: "Network services are ready."
        case .failing, .failed: "Check the Ethernet cable or BMC address."
        }
    }
}

struct ConnectionPreviewButton: View {
    let frame: ConnectionJourneyFrame
    let date: Date
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ConnectionButtonLabel(title: title, symbol: frame.phase == .connected ? "checkmark" : "power",
                                  rotating: frame.isConnecting, date: date)
        }
        .buttonStyle(ConnectionActionStyle(pressProgress: frame.phase == .pressing ? frame.phaseProgress : nil))
        .disabled(frame.isConnecting)
        .accessibilityIdentifier("overview.previewButton")
    }

    private var title: LocalizedStringKey {
        if frame.isConnecting { return "Connecting…" }
        switch frame.phase {
        case .connected: return "Connected"
        case .failed: return "Retry"
        default: return "Connect"
        }
    }
}

struct ConnectionButtonLabel: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.connectionReducedMotionPreview) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    let title: LocalizedStringKey
    let symbol: String
    var rotating = false
    var date: Date = .now

    var body: some View {
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.15) / 1.15
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .rotationEffect(.degrees(rotating && !reduceMotion
                    ? ConnectionMotion.curve(cycle, 0.42, 0, 0.58, 1) * 360 : 0))
            Text(title).font(.system(size: 14, weight: .semibold))
                .contentTransition(.opacity)
        }
        .frame(width: 204, height: 48)
    }
}
