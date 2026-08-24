import SwiftUI

/// Overview — where a session is configured and started (ticket §5.3).
///
/// Cards arrive with their phases: Interface here, then Profile, DHCP, DNS, Safety, and
/// Preflight. The scroll container and locking behaviour are established now so each card
/// only has to render itself.
struct OverviewView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProfileCard(isLocked: isLocked)
                InterfaceCard(isLocked: isLocked)

                PagePlaceholder(
                    systemImage: "slider.horizontal.3",
                    title: "More settings",
                    message: "DHCP, DNS, safety confirmation, and preflight are added in later phases.",
                    identifier: "overview.pendingCards"
                )
                .frame(minHeight: 160)
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("overview.page")
    }

    /// Configuration is read-only while anything is running or transitioning: the values are
    /// what the running session was started with, and editing them would misrepresent it.
    private var isLocked: Bool {
        appState.runtimePhase == .running || appState.runtimePhase.isTransitioning
    }
}
