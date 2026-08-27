import MacNetModels
import SwiftUI

/// Overview → Safety.
///
/// ## Why this exists at all
///
/// Every other guard in this product is something software can decide: is this Wi-Fi, does it
/// carry the default route, is the pool valid. None of them can tell an isolated lab switch
/// from a live office one — the cable looks identical and so does the interface. This checkbox
/// is the only thing standing between a mistyped port and a building-wide outage, which is why
/// it cannot be remembered, cannot be pre-ticked, and resets whenever anything it referred to
/// changes.
struct SafetyCard: View {
    @Environment(SessionController.self) private var session

    let interfaceName: String?
    let poolDescription: String?
    let isLocked: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "DHCP can disrupt an existing network.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(.orange)

                Text("Devices on the network you connect to will take addresses from Dnsmasq for Mac instead of from their usual DHCP server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: confirmationBinding) {
                    Text("I confirm that \(interfaceLabel) is connected only to the intended isolated device or lab network.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .disabled(isLocked || interfaceName == nil)
                .accessibilityIdentifier("overview.safetyConfirmation")

                if let poolDescription {
                    Text("Addresses will be handed out from \(poolDescription).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("This confirmation is not saved. It resets when you stop, change interface, or change the address pool.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } label: {
            Label("Safety", systemImage: "hand.raised.fill")
                .font(.headline)
        }
    }

    private var interfaceLabel: String {
        interfaceName ?? "the selected interface"
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { session.isolationConfirmed },
            set: { session.isolationConfirmed = $0 }
        )
    }
}
