import Foundation

/// Resolves the complete dependency set before any app state is constructed.
@MainActor
struct AppDependencies {
    let helper: any HelperLifecycleClient
    let profiles: ProfileLibrary
    let interfaces: InterfaceMonitor
    #if DEBUG
    let fixtureProfileDirectory: URL?
    #endif

    static func resolve(
        environment: AppEnvironment,
        launchEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppDependencies {
        #if DEBUG
        if let scenario = launchEnvironment["DFM_UI_FIXTURE"] {
            return try UITestFixture.dependencies(scenario: scenario)
        }
        return AppDependencies(helper: HelperClient(environment: environment), profiles: ProfileLibrary(),
                               interfaces: InterfaceMonitor(), fixtureProfileDirectory: nil)
        #else
        return AppDependencies(helper: HelperClient(environment: environment), profiles: ProfileLibrary(),
                               interfaces: InterfaceMonitor())
        #endif
    }
}
