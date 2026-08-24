import MacNetModels
import SwiftUI

/// The Leases page (ticket §5.4).
///
/// The screen an engineer watches while waiting for a device to come up. Its most important
/// property is that the three "no leases" situations look different from each other: not
/// running, running but nothing has asked yet, and running with clients — because the first
/// two call for completely different next actions.
struct LeasesView: View {
    @Environment(LeaseMonitor.self) private var monitor
    @Environment(SessionController.self) private var session

    @State private var selection: DHCPLease.ID?

    var body: some View {
        Group {
            if !session.isRunning {
                notRunningState
            } else if monitor.leases.isEmpty {
                waitingState
            } else {
                table
            }
        }
        .accessibilityIdentifier("leases.page")
        .onChange(of: session.activeSession?.id, initial: true) { _, sessionID in
            if let sessionID {
                monitor.start(sessionID: sessionID)
            } else {
                monitor.stop()
            }
        }
    }

    // MARK: - Empty states

    private var notRunningState: some View {
        ContentUnavailableView {
            Label("No active DHCP session.", systemImage: "list.bullet.rectangle")
        } description: {
            Text("Start a session on the Overview page to see devices as they request addresses.")
        }
        .accessibilityIdentifier("leases.emptyNotRunning")
    }

    private var waitingState: some View {
        ContentUnavailableView {
            Label("Waiting for DHCP clients…", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            // Distinct from "not running" on purpose: here the service *is* up, so the next
            // thing to check is the cable and whether the device has power — not MacNetLab.
            Text("The service is running. Devices will appear here as they request an address.")
        }
        .accessibilityIdentifier("leases.emptyWaiting")
    }

    // MARK: - Table

    private var table: some View {
        VStack(spacing: 0) {
            Table(monitor.leases, selection: $selection) {
                TableColumn("Status") { lease in
                    statusLabel(lease)
                }
                .width(min: 80, ideal: 90)

                TableColumn("IP Address") { lease in
                    Text(verbatim: lease.ipv4Address.description)
                        .monospacedDigit()
                }
                .width(min: 110, ideal: 130)

                TableColumn("MAC Address") { lease in
                    Text(verbatim: lease.macAddress)
                        .monospaced()
                }
                .width(min: 140, ideal: 160)

                TableColumn("Hostname") { lease in
                    Text(verbatim: lease.hostname ?? "—")
                        .foregroundStyle(lease.hostname == nil ? .secondary : .primary)
                }
                .width(min: 100, ideal: 140)

                TableColumn("Client ID") { lease in
                    Text(verbatim: lease.clientID ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 160)

                TableColumn("Expires") { lease in
                    expiryLabel(lease)
                }
                .width(min: 110, ideal: 130)

                TableColumn("Remaining") { lease in
                    remainingLabel(lease)
                }
                .width(min: 90, ideal: 110)
            }
            .contextMenu(forSelectionType: DHCPLease.ID.self) { ids in
                copyMenu(for: ids)
            }
            .accessibilityIdentifier("leases.table")

            if malformedNotice != nil {
                Divider()
                malformedBanner
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ lease: DHCPLease) -> some View {
        // Text and symbol together, never colour alone (ticket §5.2, §26.2).
        switch lease.status {
        case .active:
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .expired:
            Label("Expired", systemImage: "clock.badge.xmark")
                .foregroundStyle(.secondary)
        case .infinite:
            Label("Never expires", systemImage: "infinity")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func expiryLabel(_ lease: DHCPLease) -> some View {
        if let expiresAt = lease.expiresAt {
            Text(expiresAt, style: .time)
                .monospacedDigit()
                .foregroundStyle(lease.status == .expired ? .secondary : .primary)
        } else {
            Text(verbatim: "—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func remainingLabel(_ lease: DHCPLease) -> some View {
        // Recomputed from the monitor's shared tick, so every row shows the same instant and
        // the whole table invalidates once per second rather than once per row.
        if let remaining = lease.remaining(asOf: monitor.now) {
            Text(
                Duration.seconds(remaining).formatted(
                    .units(allowed: [.hours, .minutes, .seconds], width: .narrow)
                )
            )
            .monospacedDigit()
        } else {
            Text(verbatim: "—").foregroundStyle(.secondary)
        }
    }

    // MARK: - Copying

    /// Copying is the whole reason this table exists: the next thing an engineer does with an
    /// address is paste it into a browser or an ssh command.
    @ViewBuilder
    private func copyMenu(for ids: Set<DHCPLease.ID>) -> some View {
        let selected = monitor.leases.filter { ids.contains($0.id) }

        if selected.isEmpty {
            EmptyView()
        } else {
            Button("Copy IP Address") {
                copy(selected.map(\.ipv4Address.description))
            }
            Button("Copy MAC Address") {
                copy(selected.map(\.macAddress))
            }
            Button("Copy Hostname") {
                copy(selected.compactMap(\.hostname))
            }
            .disabled(selected.allSatisfy { $0.hostname == nil })

            Divider()

            Button("Copy Row") {
                copy(selected.map { lease in
                    [
                        lease.ipv4Address.description,
                        lease.macAddress,
                        lease.hostname ?? "",
                        lease.clientID ?? "",
                    ].joined(separator: "\t")
                })
            }
        }
    }

    private func copy(_ values: [String]) {
        guard !values.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Malformed lines

    private var malformedNotice: String? {
        guard monitor.malformedLineCount > 0 else { return nil }
        return monitor.malformedLineCount == 1
            ? "1 line in the lease file could not be read."
            : "\(monitor.malformedLineCount) lines in the lease file could not be read."
    }

    @ViewBuilder
    private var malformedBanner: some View {
        if let malformedNotice {
            // Surfaced rather than hidden: a table quietly showing three of five leases would
            // send someone chasing a device that is actually fine.
            Label(malformedNotice, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}
