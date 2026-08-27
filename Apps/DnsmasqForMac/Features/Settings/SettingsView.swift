import SwiftUI

struct SettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(SessionController.self) private var session

    var body: some View {
        Form {
            Section("Application") {
                LabeledContent("Version", value: appEnvironment.appVersion)
                LabeledContent("Build", value: appEnvironment.buildNumber)
                LabeledContent("Bundle Identifier", value: appEnvironment.bundleIdentifier)
                LabeledContent("macOS", value: appEnvironment.operatingSystemVersion)
                LabeledContent("Architecture", value: appEnvironment.architecture)
            }

            HelperStatusSection(isSessionRunning: session.isRunning)

            EngineSection()

            LicensesSection()

            Section("Privacy") {
                Text("Dnsmasq for Mac does not collect analytics, upload logs, or send network configuration to external services.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.page")
    }
}
