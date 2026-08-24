import SwiftUI

@main
struct MacNetLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var appState = AppState()
    @State private var router = AppRouter()
    @State private var helperStatus: HelperStatusModel

    private let environment: AppEnvironment

    init() {
        let environment = AppEnvironment.resolve()
        self.environment = environment
        _helperStatus = State(wrappedValue: HelperStatusModel(environment: environment))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(router)
                .environment(helperStatus)
                .environment(\.appEnvironment, environment)
                // Ticket §10.2: check on launch so the user learns the helper needs
                // attention immediately, rather than when Start fails.
                .task { await helperStatus.refresh() }
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

private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppEnvironment.resolve()
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
