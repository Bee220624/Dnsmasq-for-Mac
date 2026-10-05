import SwiftUI

/// Shares the same start, stop and cleanup actions across the overview and status bar.
struct SessionActionButton: View {
    @Environment(SessionController.self) private var session
    @Environment(ProfileLibrary.self) private var library
    @Environment(InterfaceMonitor.self) private var interfaces
    @Environment(HelperStatusModel.self) private var helper
    @Environment(\.sessionRequests) private var sessionRequests

    var prominent = false
    var presentation: ConnectionJourneyFrame?
    var animationDate: Date = .now
    var onStart: (() -> Void)?
    var onConfigure: (() -> Void)?

    var body: some View {
        if session.activeSession != nil || session.lastFailure?.code == .cleanupFailed {
            Button {
                Task { await session.stop() }
            } label: {
                actionLabel(stopTitle, systemImage: prominent && presentation?.phase == .connected
                    ? "checkmark" : "stop.fill")
            }
            .modifier(SessionActionStyleModifier(prominent: prominent, pressProgress: pressProgress))
            .buttonBorderShape(.capsule)
            .tint(prominent ? .accentColor : .red)
            .controlSize(prominent ? .large : .regular)
            .disabled(session.isBusy || presentation?.isConnecting == true)
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityIdentifier("overview.stopButton")
            .accessibilityValue(Text(session.phase.displayName))
            .help(session.activeSession == nil ? Text("Clean Up") : Text("Disconnect"))
        } else {
            Button {
                if canStart {
                    Task { await start() }
                } else {
                    onConfigure?()
                }
            } label: {
                actionLabel(startTitle, systemImage: prominent ? "power" : "play.fill")
            }
            .modifier(SessionActionStyleModifier(prominent: prominent, pressProgress: pressProgress))
            .buttonBorderShape(.capsule)
            .controlSize(prominent ? .large : .regular)
            .disabled(session.isBusy || presentation?.isConnecting == true || helper.isBusy
                      || !isHelperReady || (!canStart && onConfigure == nil))
            .accessibilityIdentifier("overview.startButton")
            .accessibilityValue(Text(canStart ? "Ready" : "Not ready"))
            .help(startHelp)
        }
    }

    @ViewBuilder
    private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        if prominent {
            ConnectionButtonLabel(
                title: presentation?.isConnecting == true ? "Connecting…" : title,
                symbol: presentation?.isConnecting == true ? "power" : systemImage,
                rotating: presentation?.isConnecting == true || session.isBusy,
                date: animationDate
            )
        } else {
            Label(title, systemImage: systemImage).frame(minWidth: 64)
        }
    }

    private var stopTitle: LocalizedStringKey {
        if session.activeSession == nil { return "Clean Up" }
        if prominent && session.isBusy { return "Disconnecting…" }
        if prominent && presentation?.phase == .connected { return "Connected" }
        return prominent ? "Disconnect" : "Stop"
    }

    private var pressProgress: Double? {
        presentation?.phase == .pressing ? presentation?.phaseProgress : nil
    }

    private var startTitle: LocalizedStringKey {
        if prominent && session.isBusy { return "Connecting…" }
        if prominent && session.lastFailure != nil { return "Retry" }
        return prominent ? "Connect" : "Start"
    }

    private var isHelperReady: Bool {
        if case .ready = helper.readiness { return true }
        return false
    }

    private var canStart: Bool {
        session.canStart(
            profile: library.draft?.working,
            hasInterface: interfaces.selected != nil,
            helperReady: isHelperReady && !helper.isBusy
        )
    }

    private var startHelp: Text {
        if !isHelperReady { return Text("Install the privileged helper in Settings first.") }
        if interfaces.selected == nil { return Text("Choose a network interface.") }
        if let profile = library.draft?.working,
           session.requiresIsolationConfirmation(for: profile), !session.isolationConfirmed {
            return Text("Confirm the interface is on an isolated network.")
        }
        if session.preflightReport?.hasBlockingIssues == true {
            return Text("Fix the problems listed under Preflight.")
        }
        if !canStart { return Text("Configure the connection before starting.") }
        return Text("Start the DHCP and DNS service.")
    }

    private func start() async {
        guard let request = sessionRequests.make(
            draft: library.draft,
            interface: interfaces.selected,
            isolationConfirmed: session.isolationConfirmed
        ) else { return }
        onStart?()
        await session.start(request)
    }
}

private struct SessionActionStyleModifier: ViewModifier {
    let prominent: Bool
    var pressProgress: Double?

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(ConnectionActionStyle(pressProgress: pressProgress))
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

struct ConnectionActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.connectionReducedMotionPreview) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    var pressProgress: Double? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background {
                Capsule().fill(ConnectionPalette.blue)
            }
            .shadow(color: ConnectionPalette.blue.opacity(isEnabled ? 0.21 : 0.08), radius: 12, y: 5)
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.72)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.96
                : pressProgress.map { 0.96 + 0.04 * ConnectionMotion.curve($0) } ?? 1))
            .animation(reduceMotion ? ConnectionMotion.fade
                       : .timingCurve(0.2, 0.8, 0.3, 1, duration: 0.22), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
