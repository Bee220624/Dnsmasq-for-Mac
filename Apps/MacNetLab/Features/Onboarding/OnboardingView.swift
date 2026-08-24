import SwiftUI

/// Shown over Overview until the privileged helper is usable (ticket §Phase 11).
///
/// ## Why this is a sheet and not a page
///
/// Nothing in this app works without the helper, so a user who has not installed it is not
/// choosing between screens — they have exactly one thing to do. Presenting Overview with
/// every control disabled would make them hunt for the reason; this states it and gives them
/// the button.
///
/// The wording carries the part macOS will not explain: that approving a background item is a
/// deliberate, one-time step, and roughly where to find it.
struct OnboardingView: View {
    @Environment(HelperStatusModel.self) private var helper

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            Text("MacNetLab needs a privileged helper")
                .font(.title2.weight(.semibold))

            Text("Serving DHCP and DNS means adding a temporary address to a network interface and listening on ports 53 and 67. Only a privileged helper can do that. MacNetLab itself never runs with administrator rights.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)

            stateSpecificContent

            Divider().frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 6) {
                Label("The helper starts only when MacNetLab asks it to.", systemImage: "bolt.slash")
                Label("Nothing starts at login or at boot.", systemImage: "power")
                Label("It accepts requests only from this app, verified by code signature.", systemImage: "lock.shield")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460, alignment: .leading)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("onboarding.page")
    }

    @ViewBuilder
    private var stateSpecificContent: some View {
        switch helper.readiness {
        case .checking, .connecting:
            ProgressView().controlSize(.small)

        case .notInstalled(.requiresApproval):
            // The one state where the app can do nothing further. macOS is waiting for a human,
            // and looping on register() would not change that (ticket §10.2).
            VStack(spacing: 10) {
                Label("Waiting for your approval", systemImage: "hand.raised.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Text("Open Login Items & Extensions, then enable MacNetLab. This window updates on its own once you do.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)

                Button("Open Login Items Settings") {
                    helper.openLoginItemsSettings()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("onboarding.openLoginItems")
            }

        case .notInstalled(.bundleIncomplete):
            VStack(spacing: 8) {
                Label("This copy of MacNetLab is incomplete", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("The helper is missing from the app bundle. Reinstall MacNetLab from your original download.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

        case .incompatible(_, let reason):
            VStack(spacing: 10) {
                Label("The installed helper does not match this app", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(verbatim: reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Repair Helper") {
                    Task { await helper.install() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(helper.isBusy)
            }

        case .failed(let failure):
            VStack(spacing: 8) {
                Label(failure.title, systemImage: "exclamationmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(verbatim: failure.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let suggestion = failure.recoverySuggestion {
                    Text(verbatim: suggestion)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Try Again") {
                    Task { await helper.install() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(helper.isBusy)
            }

        default:
            Button("Install Helper") {
                Task { await helper.install() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(helper.isBusy)
            .accessibilityIdentifier("onboarding.installHelper")
        }
    }
}
