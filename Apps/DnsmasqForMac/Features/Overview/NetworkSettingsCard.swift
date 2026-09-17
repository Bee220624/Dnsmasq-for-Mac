import MacNetModels
import MacNetValidation
import SwiftUI

struct NetworkSettingsCard: View {
    @Binding var profile: NetworkProfile
    let isLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Use DHCP for a BMC configured to request an address. For a known fixed IP, turn DHCP off and put the Mac in the same subnet; keep DNS in Local Records Only mode.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("Add temporary IPv4 address", isOn: $profile.interfaceConfiguration.addTemporaryIPv4Alias)
                    addressField("Mac IPv4 address", value: $profile.interfaceConfiguration.serverIPv4, id: "settings.serverIPv4")
                    Picker("Subnet prefix", selection: $profile.interfaceConfiguration.prefixLength) {
                        ForEach(8...30, id: \.self) { prefix in Text(verbatim: "/\(prefix)").tag(prefix) }
                    }
                    .accessibilityIdentifier("settings.prefixLength")
                    if let subnet = profile.interfaceConfiguration.subnet {
                        LabeledContent("Subnet mask", value: subnet.netmask.description)
                    }
                    Text("This is the Mac's address, not the BMC's address. Stop removes only the address added by this app.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            } label: { Label("Mac Address", systemImage: "network") }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable DHCP", isOn: $profile.dhcpConfiguration.enabled)
                        .accessibilityIdentifier("settings.dhcpEnabled")
                    if profile.dhcpConfiguration.enabled {
                        addressField("Pool start", value: $profile.dhcpConfiguration.rangeStart, id: "settings.rangeStart")
                        addressField("Pool end", value: $profile.dhcpConfiguration.rangeEnd, id: "settings.rangeEnd")
                        LeaseDurationField(seconds: $profile.dhcpConfiguration.leaseDurationSeconds)
                        Toggle("Authoritative DHCP (isolated network only)", isOn: $profile.dhcpConfiguration.authoritative)
                        Toggle("Advertise this Mac as DNS", isOn: $profile.dhcpConfiguration.advertiseLocalDNSServer)
                        Toggle("Advertise router", isOn: $profile.dhcpConfiguration.advertiseRouter)
                        if profile.dhcpConfiguration.advertiseRouter {
                            addressField("Router IPv4 address", value: Binding(
                                get: { profile.dhcpConfiguration.routerIPv4 ?? .any },
                                set: { profile.dhcpConfiguration.routerIPv4 = $0 }
                            ), id: "settings.routerIPv4")
                        }
                        Text("Leave the router option off for direct BMC access. This app does not share the Mac's internet connection.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(6)
            } label: { Label("DHCP Server", systemImage: "server.rack") }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable DNS", isOn: $profile.dnsConfiguration.enabled)
                        .accessibilityIdentifier("settings.dnsEnabled")
                    if profile.dnsConfiguration.enabled {
                        LabeledContent("Local domain") {
                            TextField("Local domain", text: $profile.dnsConfiguration.localDomain)
                                .labelsHidden()
                                .appTextFieldStyle()
                        }
                        Picker("Upstream DNS", selection: $profile.dnsConfiguration.upstreamMode) {
                            Text("Local Records Only (offline)").tag(DNSUpstreamMode.localOnly)
                            Text("System DNS").tag(DNSUpstreamMode.system)
                            Text("Custom DNS").tag(DNSUpstreamMode.custom)
                        }
                        .accessibilityIdentifier("settings.upstreamMode")
                        if profile.dnsConfiguration.upstreamMode == .custom {
                            DNSUpstreamField(addresses: $profile.dnsConfiguration.customUpstreamServers)
                        }
                        Toggle("Log DNS queries", isOn: $profile.dnsConfiguration.logQueries)
                        ForEach($profile.dnsConfiguration.records) { $record in
                            HStack {
                                Toggle("Enabled", isOn: $record.enabled).labelsHidden()
                                TextField("Hostname", text: $record.hostname)
                                addressField("IPv4", value: $record.ipv4Address, id: "settings.record.\(record.id)")
                                Button {
                                    profile.dnsConfiguration.records.removeAll { $0.id == record.id }
                                } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel(Text("Remove DNS record"))
                            }
                        }
                        Button("Add DNS record") {
                            profile.dnsConfiguration.records.append(LocalDNSRecord(hostname: "", ipv4Address: .any))
                        }
                    }
                }.padding(6)
            } label: { Label("DNS Server", systemImage: "globe") }

            ForEach(ConfigurationValidator.validate(profile)) { issue in
                Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                    .font(.callout).textSelection(.enabled)
            }
        }
        .disabled(isLocked)
    }

    private func addressField(_ title: LocalizedStringKey, value: Binding<IPv4Address>, id: String) -> some View {
        IPv4TextField(title: title, address: value)
            .accessibilityIdentifier(id)
    }
}

private struct DNSUpstreamField: View {
    @Binding var addresses: [IPv4Address]
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent("DNS IPv4 addresses (comma separated)") {
            TextField("DNS IPv4 addresses (comma separated)", text: $text)
                .labelsHidden()
                .appTextFieldStyle().focused($focused)
        }
        .onAppear { text = addresses.map(\.description).joined(separator: ", ") }
        .onChange(of: text) {
            addresses = text.split(separator: ",", omittingEmptySubsequences: false).map {
                IPv4Address($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .any
            }
        }
        .onChange(of: addresses) {
            if !focused { text = addresses.map(\.description).joined(separator: ", ") }
        }
    }
}

private struct LeaseDurationField: View {
    @Binding var seconds: Int
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent("Lease duration (seconds)") {
            TextField("Lease duration (seconds)", text: $text)
                .labelsHidden()
                .appTextFieldStyle().focused($focused)
        }
        .onAppear { text = String(seconds) }
        .onChange(of: text) { seconds = Int(text) ?? 0 }
        .onChange(of: seconds) { if !focused { text = String(seconds) } }
    }
}

/// Retains partially typed input, while marking the model invalid until the text parses.
private struct IPv4TextField: View {
    let title: LocalizedStringKey
    @Binding var address: IPv4Address
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text)
                .labelsHidden()
                .appTextFieldStyle()
                .focused($focused)
        }
        .onAppear { text = address.description }
        .onChange(of: text) {
            address = IPv4Address(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .any
        }
        .onChange(of: address) {
            if !focused { text = address.description }
        }
    }
}
