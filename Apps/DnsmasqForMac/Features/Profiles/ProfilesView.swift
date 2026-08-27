import MacNetModels
import SwiftUI

/// The Profiles page: a list on the left, a summary on the right.
struct ProfilesView: View {
    @Environment(ProfileLibrary.self) private var library
    @Environment(AppState.self) private var appState

    @State private var selection: UUID?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var deleting: NetworkProfile?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            summary
                .frame(minWidth: 320, maxWidth: .infinity)
        }
        .accessibilityIdentifier("profiles.page")
        .onAppear {
            if selection == nil { selection = library.selectedProfileID }
        }
        .alert("Rename Profile", isPresented: renamingBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                guard let id = renaming else { return }
                Task { await library.rename(profileID: id, to: renameText) }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert(item: $deleting) { profile in
            Alert(
                title: Text("Delete “\(profile.name)”?"),
                message: Text(deleteMessage(for: profile)),
                primaryButton: .destructive(Text("Delete")) {
                    Task { await library.delete(profileID: profile.id) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    /// Deleting a profile a live session is using is allowed, because the session holds its
    /// own snapshot — but the user is told plainly that it will not stop anything
    ///.
    private func deleteMessage(for profile: NetworkProfile) -> String {
        if appState.runtimePhase == .running {
            "This cannot be undone. If a session is running from this profile, it will keep "
                + "running — deleting a profile does not stop a service."
        } else {
            "This cannot be undone."
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            List(library.profiles, selection: $selection) { profile in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: profile.name)
                        Text(verbatim: summaryLine(profile))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if profile.id == library.defaultProfileID {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Default profile"))
                    }
                }
                .tag(profile.id)
                .contextMenu { contextMenu(for: profile) }
            }
            .accessibilityIdentifier("profiles.list")

            Divider()
            toolbar
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button {
                Task { await library.createProfile() }
            } label: {
                Image(systemName: "plus")
            }
            .help(Text("New profile"))
            .accessibilityLabel(Text("New profile"))
            .accessibilityIdentifier("profiles.new")

            Button {
                guard let profile = selectedProfile else { return }
                requestDelete(profile)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(!canDeleteSelection)
            .help(Text(deleteHelp))
            .accessibilityLabel(Text("Delete profile"))
            .accessibilityIdentifier("profiles.delete")

            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(6)
    }

    private func contextMenu(for profile: NetworkProfile) -> some View {
        Group {
            Button("Rename…") {
                renameText = profile.name
                renaming = profile.id
            }
            Button("Duplicate") {
                Task { await library.duplicate(profileID: profile.id) }
            }
            Button("Set as Default") {
                Task { await library.setDefault(profileID: profile.id) }
            }
            .disabled(profile.id == library.defaultProfileID)

            Divider()

            Button("Delete…", role: .destructive) {
                requestDelete(profile)
            }
            .disabled(!canDelete(profile))
        }
    }

    // MARK: - Deletion rules

    private var selectedProfile: NetworkProfile? {
        selection.flatMap { id in library.profiles.first { $0.id == id } }
    }

    private var canDeleteSelection: Bool {
        selectedProfile.map(canDelete) ?? false
    }

    /// The specification: one profile must always remain, and the default must be reassigned before
    /// it can be removed.
    private func canDelete(_ profile: NetworkProfile) -> Bool {
        library.profiles.count > 1 && profile.id != library.defaultProfileID
    }

    private var deleteHelp: LocalizedStringKey {
        guard let profile = selectedProfile else { return "Select a profile to delete" }
        if library.profiles.count <= 1 { return "At least one profile must remain" }
        if profile.id == library.defaultProfileID {
            return "Make another profile the default first"
        }
        return "Delete this profile"
    }

    private func requestDelete(_ profile: NetworkProfile) {
        guard canDelete(profile) else { return }
        deleting = profile
    }

    // MARK: - Summary

    @ViewBuilder
    private var summary: some View {
        if let profile = selectedProfile {
            ScrollView {
                Form {
                    Section("Profile") {
                        LabeledContent("Name", value: profile.name)
                        LabeledContent("Default", value: profile.id == library.defaultProfileID
                                       ? "Yes" : "No")
                        LabeledContent("Updated", value: profile.updatedAt.formatted(
                            date: .abbreviated, time: .shortened))
                    }

                    Section("Addressing") {
                        LabeledContent("Server IPv4",
                                       value: "\(profile.interfaceConfiguration.serverIPv4)"
                                       + "/\(profile.interfaceConfiguration.prefixLength)")
                        if let subnet = profile.interfaceConfiguration.subnet {
                            LabeledContent("Network", value: subnet.networkAddress.description)
                            LabeledContent("Broadcast", value: subnet.broadcastAddress.description)
                        }
                        LabeledContent("Temporary alias",
                                       value: profile.interfaceConfiguration.addTemporaryIPv4Alias
                                       ? "Added on start" : "Not added")
                    }

                    Section("DHCP") {
                        if profile.dhcpConfiguration.enabled {
                            LabeledContent("Range",
                                           value: "\(profile.dhcpConfiguration.rangeStart) – "
                                           + "\(profile.dhcpConfiguration.rangeEnd)")
                            LabeledContent("Addresses",
                                           value: profile.dhcpConfiguration.poolSize
                                               .map(String.init) ?? "—")
                            LabeledContent("Lease", value: leaseText(profile))
                            LabeledContent("Authoritative",
                                           value: profile.dhcpConfiguration.authoritative
                                           ? "Yes" : "No")
                        } else {
                            Text("Disabled").foregroundStyle(.secondary)
                        }
                    }

                    Section("DNS") {
                        if profile.dnsConfiguration.enabled {
                            LabeledContent("Local domain",
                                           value: profile.dnsConfiguration.localDomain)
                            LabeledContent("Upstream",
                                           value: upstreamText(profile.dnsConfiguration))
                            LabeledContent("Local records",
                                           value: "\(profile.dnsConfiguration.records.count)")
                        } else {
                            Text("Disabled").foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        } else {
            ContentUnavailableView(
                "No Profile Selected",
                systemImage: "square.stack.3d.up",
                description: Text("Choose a profile to see its settings.")
            )
        }
    }

    private func summaryLine(_ profile: NetworkProfile) -> String {
        var parts = ["\(profile.interfaceConfiguration.serverIPv4)"
            + "/\(profile.interfaceConfiguration.prefixLength)"]
        if profile.dhcpConfiguration.enabled { parts.append("DHCP") }
        if profile.dnsConfiguration.enabled { parts.append("DNS") }
        return parts.joined(separator: " · ")
    }

    private func leaseText(_ profile: NetworkProfile) -> String {
        let seconds = profile.dhcpConfiguration.leaseDurationSeconds
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .wide)
        )
    }

    private func upstreamText(_ dns: DNSConfiguration) -> String {
        switch dns.upstreamMode {
        case .system: "System DNS"
        case .localOnly: "Local records only"
        case .custom: dns.customUpstreamServers.isEmpty
            ? "Custom (none set)"
            : dns.customUpstreamServers.map(\.description).joined(separator: ", ")
        }
    }
}

// `alert(item:)` needs the payload to be Identifiable; NetworkProfile already is.
