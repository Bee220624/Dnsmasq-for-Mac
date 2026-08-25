import MacNetInterfaces
import MacNetModels
import SwiftUI

/// Overview → Interface (ticket §5.3.2).
///
/// Shows every interface on the machine, including the ones that cannot be used. Hiding a
/// refused interface would look exactly like the adapter not being detected, and the engineer
/// standing in a datacenter would spend their time re-seating a cable that is fine.
struct InterfaceCard: View {
    @Environment(InterfaceMonitor.self) private var monitor

    /// Locked while a session is running: the interface is part of what is running, and
    /// changing it under a live dnsmasq is meaningless (ticket §Phase 8).
    let isLocked: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                picker
                Divider()
                detail
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Label("Interface", systemImage: "cable.connector")
                    .font(.headline)
                Spacer()
                Button {
                    monitor.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(isLocked)
                .help(Text("Re-scan network interfaces"))
                .accessibilityLabel(Text("Refresh interfaces"))
                .accessibilityIdentifier("overview.refreshInterfaces")
            }
        }
    }

    // MARK: - Picker

    @ViewBuilder
    private var picker: some View {
        if monitor.interfaces.isEmpty && monitor.hasLoaded {
            Label("No network interfaces found.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else {
            Picker(selection: selectionBinding) {
                if monitor.selected == nil {
                    Text("Choose an interface…").tag(String?.none)
                }
                ForEach(monitor.interfaces) { interface in
                    row(for: interface)
                        .tag(String?.some(interface.bsdName))
                        // A refused interface stays listed but cannot be chosen, and its
                        // reason is shown below the picker once selected.
                        .disabled(!interface.isSupported)
                }
            } label: {
                Text("Interface")
            }
            .pickerStyle(.menu)
            .disabled(isLocked)
            .accessibilityIdentifier("overview.interfacePicker")
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { monitor.selectedBSDName },
            set: { if let value = $0 { monitor.select(value) } }
        )
    }

    /// One picker row: `USB 10/100/1000 LAN — en7 — Connected`, with hardware details
    /// beneath (ticket §5.3.2).
    private func row(for interface: NetworkInterfaceDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(interface.displayName) — \(interface.bsdName) — \(linkText(interface))")
            Text(verbatim: secondaryLine(interface))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The picker row composes one line out of several values, so this resolves the phrase
    /// itself rather than returning a key the surrounding `Text(verbatim:)` would not look up.
    private func linkText(_ interface: NetworkInterfaceDescriptor) -> String {
        guard interface.isSupported else { return String(localized: "Unavailable") }
        return interface.isLinkActive
            ? String(localized: "Connected")
            : String(localized: "No link")
    }

    private func secondaryLine(_ interface: NetworkInterfaceDescriptor) -> String {
        var parts: [String] = []
        if let mac = interface.macAddress { parts.append(mac) }
        if let first = interface.ipv4Addresses.first { parts.append(first.address.description) }
        parts.append(interface.kind.localizedNameString)
        return parts.joined(separator: " · ")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let interface = monitor.selected {
            VStack(alignment: .leading, spacing: 6) {
                field("Hardware Port", interface.hardwarePortName ?? interface.displayName)
                field("BSD Name", interface.bsdName)
                localizedField("Type", interface.kind.localizedName)
                field("MAC Address", interface.macAddress ?? "—")
                linkField(interface)
                addressField(interface)
                defaultRouteField(interface)
            }
            .accessibilityIdentifier("overview.interfaceDetail")
        } else {
            unselectedExplanation
        }
    }

    /// A field whose value is itself a localized key rather than data.
    private func localizedField(
        _ label: LocalizedStringKey,
        _ value: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.callout)
            Spacer()
        }
    }

    private func field(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(verbatim: value)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func linkField(_ interface: NetworkInterfaceDescriptor) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Link")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            // Text and symbol, never colour alone (ticket §26.2).
            Label(
                interface.isLinkActive ? "Connected" : "No link detected",
                systemImage: interface.isLinkActive ? "cable.connector" : "cable.connector.slash"
            )
            .font(.callout)
            .foregroundStyle(interface.isLinkActive ? .primary : .secondary)
            Spacer()
        }
    }

    private func addressField(_ interface: NetworkInterfaceDescriptor) -> some View {
        let addresses = interface.ipv4Addresses.map { entry in
            entry.prefixLength.map { "\(entry.address)/\($0)" } ?? entry.address.description
        }
        return field("Current IPv4", addresses.isEmpty ? "None" : addresses.joined(separator: ", "))
    }

    @ViewBuilder
    private func defaultRouteField(_ interface: NetworkInterfaceDescriptor) -> some View {
        if interface.isDefaultRoute {
            Label(
                "This interface carries this Mac's internet connection.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Explains why nothing is selected. The distinction matters: "still scanning", "no
    /// adapter plugged in", and "an adapter is present but cannot be used" call for three
    /// different actions from the user.
    @ViewBuilder
    private var unselectedExplanation: some View {
        if !monitor.hasLoaded {
            Label("Scanning…", systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
        } else if monitor.selectableInterfaces.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("No usable interface", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Connect a USB or Thunderbolt Ethernet adapter. Wi-Fi and the interface carrying this Mac's internet connection cannot be used.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Choose the adapter connected to your device network.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
