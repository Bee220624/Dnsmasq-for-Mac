import SwiftUI

@main
struct MacNetLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var appState = AppState()
    @State private var router = AppRouter()

    private let environment = AppEnvironment.resolve()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(router)
                .environment(\.appEnvironment, environment)
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
