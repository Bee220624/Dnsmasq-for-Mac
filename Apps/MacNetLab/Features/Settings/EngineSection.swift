import MacNetModels
import SwiftUI

/// Settings → dnsmasq Engine (ticket §5.7).
///
/// Reports what the **helper** found, not what the app was compiled believing. That
/// distinction is the point: the helper is the process that will run this binary as root, and
/// its answer is the one that decides whether a session can start.
struct EngineSection: View {
    @Environment(HelperStatusModel.self) private var model

    var body: some View {
        Section("dnsmasq Engine") {
            if let engine = connectedEngine {
                LabeledContent("Version", value: engine.version)
                LabeledContent("Architecture", value: engine.architectures)

                LabeledContent("SHA-256") {
                    Text(verbatim: engine.sha256)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                DisclosureGroup("Compile Options") {
                    Text(verbatim: engine.compileOptions)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Label(
                    "Verified. The helper re-checks the engine's signature before every start.",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.callout)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.engineVerified")

            } else if isConnected {
                // Connected, but the engine did not verify. This is a hard stop, not a
                // cosmetic gap: the helper will refuse to launch it.
                Label(
                    "The bundled engine could not be verified. No session can be started.",
                    systemImage: "xmark.shield.fill"
                )
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.engineUnverified")

                Text("Reinstall MacNetLab from your original download.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            } else {
                Text("Connect to the privileged helper to see engine details.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("Verify Now") {
                Task { await model.refresh() }
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("settings.verifyEngine")
        }
    }

    private var connectedEngine: HelperServiceInfo.EngineVerification? {
        switch model.readiness {
        case .ready(let info), .incompatible(let info, _): info.engine
        default: nil
        }
    }

    private var isConnected: Bool {
        switch model.readiness {
        case .ready, .incompatible: true
        default: false
        }
    }
}

/// Settings → Licenses (ticket §5.7, §23).
struct LicensesSection: View {
    @State private var showingNotices = false

    var body: some View {
        Section("Licenses") {
            LabeledContent("dnsmasq") {
                Text(verbatim: "GPL v2 or GPL v3")
                    .foregroundStyle(.secondary)
            }

            Text("MacNetLab bundles dnsmasq by Simon Kelley as a separate, unmodified program. No dnsmasq code is compiled or linked into MacNetLab itself.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Third-Party Notices…") {
                showingNotices = true
            }
            .accessibilityIdentifier("settings.thirdPartyNotices")

            if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "md") {
                Link("Open Notices File", destination: url)
                    .font(.callout)
            }
        }
        .sheet(isPresented: $showingNotices) {
            NoticesSheet()
        }
    }
}

/// Shows the bundled third-party notices.
private struct NoticesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Third-Party Notices").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                Text(verbatim: text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task {
            // Read from the bundle rather than hardcoded, so the shipped notices and the
            // displayed notices cannot drift apart.
            guard let url = Bundle.main.url(
                forResource: "ThirdPartyNotices", withExtension: "md"
            ), let contents = try? String(contentsOf: url, encoding: .utf8) else {
                text = String(localized: "The notices file is missing from this build.")
                return
            }
            text = contents
        }
    }
}
