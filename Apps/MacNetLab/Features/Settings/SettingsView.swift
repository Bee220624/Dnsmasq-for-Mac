import SwiftUI

struct SettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Application") {
                LabeledContent("Version", value: appEnvironment.appVersion)
                LabeledContent("Build", value: appEnvironment.buildNumber)
                LabeledContent("Bundle Identifier", value: appEnvironment.bundleIdentifier)
                LabeledContent("macOS", value: appEnvironment.operatingSystemVersion)
                LabeledContent("Architecture", value: appEnvironment.architecture)
            }

            HelperStatusSection(isSessionRunning: appState.runtimePhase == .running)

            Section("Privacy") {
                Text("MacNetLab does not collect analytics, upload logs, or send network configuration to external services.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.page")
    }
}
