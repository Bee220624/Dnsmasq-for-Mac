import SwiftUI

/// Main window shell: fixed sidebar, persistent status bar, and the selected page.
struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(HelperStatusModel.self) private var helper

    var body: some View {
        @Bindable var router = router

        NavigationSplitView {
            List(AppSection.allCases, selection: Binding(
                get: { router.selectedSection },
                set: { router.selectedSection = $0 ?? .overview }
            )) { section in
                NavigationLink(value: section) {
                    Label(section.navigationTitle, systemImage: section.systemImage)
                }
                .accessibilityIdentifier("sidebar.\(section.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if router.selectedSection != .overview || !isHelperReady {
                    GlobalStatusBar()
                    Divider()
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(router.selectedSection.navigationTitle)
        }
    }

    private var isHelperReady: Bool {
        if case .ready = helper.readiness { return true }
        return false
    }

    @ViewBuilder
    private var detail: some View {
        switch router.selectedSection {
        case .overview: OverviewView()
        case .leases: LeasesView()
        case .logs: LogsView()
        case .profiles: ProfilesView()
        case .settings: SettingsView()
        }
    }
}

extension AppSection {
    var navigationTitle: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .leases: "Leases"
        case .logs: "Logs"
        case .profiles: "Profiles"
        case .settings: "Settings"
        }
    }
}
