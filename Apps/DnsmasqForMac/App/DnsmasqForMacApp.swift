import SwiftUI

@main
struct DnsmasqForMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var appState = AppState()
    @State private var router = AppRouter()
    @State private var helperStatus: HelperStatusModel
    @State private var interfaces = InterfaceMonitor()
    @State private var profiles = ProfileLibrary()
    @State private var session: SessionController
    @State private var leases: LeaseMonitor
    @State private var logs: LogMonitor

    private let environment: AppEnvironment

    init() {
        let environment = AppEnvironment.resolve()
        self.environment = environment
        let helperStatus = HelperStatusModel(environment: environment)
        _helperStatus = State(wrappedValue: helperStatus)
        // One XPC client shared by both: a second connection would mean the helper
        // serving two peers that each believe they own the session state.
        _session = State(wrappedValue: SessionController(client: helperStatus.client))
        _leases = State(wrappedValue: LeaseMonitor(client: helperStatus.client))
        _logs = State(wrappedValue: LogMonitor(client: helperStatus.client))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(router)
                .environment(helperStatus)
                .environment(interfaces)
                .environment(profiles)
                .environment(session)
                .environment(leases)
                .environment(logs)
                .environment(\.appEnvironment, environment)
                // Ticket §10.2: check on launch so the user learns the helper needs
                // attention immediately, rather than when Start fails.
                .task { await helperStatus.refresh() }
                .task { await profiles.load() }
                // Ticket §17.1: adopt whatever the helper is already doing, so a
                // session that survived a force-quit is visible and stoppable.
                .task { await session.synchronize() }
                // The delegate is created by AppKit before any SwiftUI state, so
                // the quit handler is joined to the controller here.
                .onAppear { AppDelegate.sessionController = session }
                // Enumerate immediately and keep watching: an adapter plugged in while
                // the app is open should appear without the user hunting for a refresh.
                .onAppear { interfaces.start() }
                .onDisappear { interfaces.stop() }
                // Ticket §5.1: minimum window 1000 x 680.
                .frame(minWidth: 1000, minHeight: 680)
        }
        // Ticket §5.1: default window 1180 x 760.
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            // The app has no document model, so the New/Open items would all be dead.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
