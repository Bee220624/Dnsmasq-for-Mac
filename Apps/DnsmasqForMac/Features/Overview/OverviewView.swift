import MacNetModels
import MacNetXPC
import SwiftUI

/// A quiet connection panel, with configuration available when it is needed.
struct OverviewView: View {
    @Environment(HelperStatusModel.self) private var helper

    var body: some View {
        if case .ready = helper.readiness {
            ConnectionOverview()
        } else {
            OnboardingView()
        }
    }
}

struct ConnectionOverview: View {
    @Environment(ProfileLibrary.self) private var library
    @Environment(InterfaceMonitor.self) private var interfaces
    @Environment(SessionController.self) private var session
    @Environment(HelperStatusModel.self) private var helper
    @Environment(\.sessionRequests) private var sessionRequests
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var settingsExpanded = false
    @State private var journey = ConnectionJourney()
    @State private var tunnelVisible = true
    @State private var previewEnabled = false
    @State private var previewReducedMotion = false
    @State private var previewOutcome = ConnectionJourneyOutcome.success
    @State private var previewRunID: UUID?

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        connectionPanel
                            .frame(minHeight: max(490, geometry.size.height - 130))
                            .id("connection")

                        notices

                        #if DEBUG
                        previewControls
                        #endif

                        DisclosureGroup(isExpanded: Binding(
                            get: { settingsExpanded },
                            set: { expanded in
                                withAnimation(reduceMotion ? nil : ConnectionMotion.animation) {
                                    settingsExpanded = expanded
                                }
                            }
                        )) {
                            configuration
                                .padding(.top, 20)
                                .transition(.opacity)
                        } label: {
                            Label("Connection settings", systemImage: "slider.horizontal.3")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(18)
                        .background(.quaternary.opacity(settingsExpanded ? 0.3 : 0),
                                    in: RoundedRectangle(cornerRadius: 16))
                        .id("configuration")
                        .accessibilityIdentifier("overview.connectionSettings")
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: settingsExpanded) {
                    if settingsExpanded {
                        withAnimation(reduceMotion ? nil : ConnectionMotion.animation) {
                            scroll.scrollTo("configuration", anchor: .top)
                        }
                    }
                }
                .onChange(of: session.phase) {
                    synchronizePresentation()
                    if session.phase == .starting || session.phase == .running {
                        withAnimation(reduceMotion ? nil : ConnectionMotion.animation) {
                            settingsExpanded = false
                            scroll.scrollTo("connection", anchor: .top)
                        }
                    }
                }
                .onPreferenceChange(ConnectionBoundsPreference.self) { bounds in
                    guard !bounds.isEmpty else { return }
                    tunnelVisible = bounds.intersects(CGRect(origin: .zero, size: geometry.size))
                }
            }
        }
        .coordinateSpace(name: "connectionViewport")
        .background(.white)
        .preferredColorScheme(.light)
        .tint(ConnectionPalette.blue)
        .environment(\.connectionReducedMotionPreview, previewEnabled && previewReducedMotion)
        .onAppear { synchronizePresentation(initial: true) }
        .onChange(of: session.lastFailure) { synchronizePresentation() }
        .onChange(of: previewEnabled) {
            previewRunID = nil
            journey.reset()
            if !previewEnabled { synchronizePresentation(initial: true) }
        }
        .onDisappear {
            previewRunID = nil
            if previewEnabled { journey.reset() }
        }
        .task(id: previewRunID) {
            guard let runID = previewRunID else { return }
            let outcome = previewOutcome
            do {
                try await Task.sleep(for: .seconds(1.75))
                guard previewEnabled, previewRunID == runID else { return }
                journey.resolve(outcome)
            } catch { /* Leaving preview cancels its pending outcome. */ }
        }
        .safeAreaInset(edge: .bottom) {
            if settingsExpanded && !previewEnabled {
                HStack {
                    Text("Connection settings")
                        .font(.headline)
                    Spacer()
                    SessionActionButton(prominent: true, onStart: beginConnection)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .accessibilityIdentifier("overview.page")
    }

    private var connectionPanel: some View {
        ConnectionExperience(
            journey: journey, isPaused: !tunnelVisible,
            summary: connectionSummary, titleOverride: titleOverride,
            hintOverride: hintOverride, statusValue: session.phase.displayName
        ) { frame, date in
            if previewEnabled {
                VStack(spacing: 10) {
                    ConnectionPreviewButton(frame: frame, date: date, action: beginPreview)
                    Text("Animation preview only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("overview.previewPhase")
                        .accessibilityValue(frame.phase.rawValue.capitalized)
                }
            } else if !settingsExpanded {
                SessionActionButton(prominent: true, presentation: frame, animationDate: date,
                                    onStart: beginConnection) {
                    withAnimation(reduceMotion ? nil : ConnectionMotion.animation) { settingsExpanded = true }
                }
            } else {
                Color.clear.frame(height: 48)
            }
        }
        .background {
            GeometryReader { bounds in
                Color.clear.preference(
                    key: ConnectionBoundsPreference.self,
                    value: bounds.frame(in: .named("connectionViewport"))
                )
            }
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            if let profile = library.workingProfile {
                NetworkSettingsCard(profile: profile, isLocked: isLocked)
                    .id(library.selectedProfileID)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let failure = session.lastFailure {
            FailureBanner(failure: failure) { session.clearFailure() }
                .padding(.bottom, 16)
        }
        if !session.recoveryWarnings.isEmpty {
            recoveryBanner.padding(.bottom, 16)
        }
    }

    // MARK: - State

    private var titleOverride: LocalizedStringKey? {
        guard !previewEnabled else { return nil }
        switch session.phase {
        case .stopping: return "Disconnecting"
        case .recovering: return "Restoring your session"
        case .preflighting: return "Making the connection"
        default: return nil
        }
    }

    private var hintOverride: LocalizedStringKey? {
        guard !previewEnabled else { return nil }
        switch session.phase {
        case .stopping: return "Stopping services and restoring your network."
        case .recovering: return "Checking the previous session."
        default: return nil
        }
    }

    private var connectionSummary: String {
        [
            session.activeSession?.profileSnapshot.name ?? library.draft?.working.name,
            session.activeSession?.interfaceSnapshot.bsdName ?? interfaces.selected?.bsdName
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    /// Configuration is read-only while anything is running or transitioning: the values are
    /// what the running session was started with, and editing them would misrepresent it.
    private var isLocked: Bool {
        session.activeSession != nil || session.isBusy
    }

    private var canValidate: Bool {
        library.draft != nil && interfaces.selected != nil && !session.isRunning && !helper.isBusy
    }

    private func poolDescription(_ profile: NetworkProfile) -> String? {
        guard profile.dhcpConfiguration.enabled else { return nil }
        return "\(profile.dhcpConfiguration.rangeStart) – \(profile.dhcpConfiguration.rangeEnd)"
    }

    // MARK: - Actions

    private func beginConnection() {
        journey.begin()
    }

    private func beginPreview() {
        journey.begin()
        previewRunID = UUID()
    }

    private func synchronizePresentation(initial: Bool = false) {
        guard !previewEnabled else { return }
        let frame = journey.frame()
        if session.lastFailure != nil || session.phase == .failed {
            if !initial && frame.isConnecting { journey.resolve(.failure) }
            else { journey.settle(.failure) }
        } else if session.phase == .running {
            if !initial && frame.isConnecting { journey.resolve(.success) }
            else { journey.settle(.success) }
        } else if session.phase == .starting {
            if !frame.isConnecting { journey.begin() }
        } else if session.phase == .stopped {
            journey.reset()
        }
    }

    #if DEBUG
    private var previewControls: some View {
        HStack(spacing: 16) {
            Toggle("Animation debug", isOn: $previewEnabled)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("overview.animationDebug")
            if previewEnabled {
                Picker("Preview outcome", selection: $previewOutcome) {
                    Text("Success").tag(ConnectionJourneyOutcome.success)
                    Text("Failure").tag(ConnectionJourneyOutcome.failure)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .accessibilityIdentifier("overview.previewOutcome")
                Toggle("Reduce motion", isOn: $previewReducedMotion)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("overview.previewReducedMotion")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }
    #endif

    private func runPreflight() async {
        guard let request = sessionRequests.make(
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

private struct ConnectionBoundsPreference: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let bounds = nextValue()
        if !bounds.isEmpty { value = bounds }
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
