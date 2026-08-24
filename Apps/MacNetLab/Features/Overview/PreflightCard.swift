import MacNetModels
import SwiftUI

/// Overview → Preflight (ticket §5.3.6).
///
/// Shows the whole checklist, including checks that have not run — so the user can see what
/// *will* be verified, not only what happened to fail. Warnings are displayed prominently and
/// never block Start; only errors do.
struct PreflightCard: View {
    @Environment(SessionController.self) private var session

    let canValidate: Bool
    let onValidate: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                checklist

                if let report = session.preflightReport, !report.issues.isEmpty {
                    Divider()
                    issues(report)
                }

                if let output = session.preflightReport?.configurationTestOutput,
                   !output.isEmpty {
                    DisclosureGroup("Configuration Check Output") {
                        Text(verbatim: output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }

                HStack {
                    Button("Validate Configuration", action: onValidate)
                        .disabled(!canValidate || session.isBusy)
                        .accessibilityIdentifier("overview.validateButton")

                    if session.phase == .preflighting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Preflight", systemImage: "checklist")
                .font(.headline)
        }
    }

    // MARK: - Checklist

    private var checklist: some View {
        // The pending report is used when nothing has run yet, so the list is the same length
        // and in the same order either way — the rows do not jump around after validating.
        let report = session.preflightReport ?? .pending(at: .distantPast)

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(report.checks) { result in
                HStack(spacing: 8) {
                    icon(for: result.status)
                        .frame(width: 16)
                    Text(title(for: result.check))
                        .font(.callout)
                        .foregroundStyle(result.status == .pending ? .secondary : .primary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(title(for: result.check)))
                .accessibilityValue(Text(statusLabel(result.status)))
            }
        }
    }

    /// Symbol and colour together — never colour alone (ticket §26.2).
    @ViewBuilder
    private func icon(for status: PreflightCheckStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func statusLabel(_ status: PreflightCheckStatus) -> LocalizedStringKey {
        switch status {
        case .pending: "Not checked yet"
        case .passed: "Passed"
        case .warning: "Warning"
        case .failed: "Failed"
        }
    }

    private func title(for check: PreflightCheck) -> LocalizedStringKey {
        switch check {
        case .helperInstalled: "Helper installed"
        case .helperVersionCompatible: "Helper version compatible"
        case .dnsmasqBinaryVerified: "dnsmasq binary verified"
        case .interfaceSupported: "Interface supported"
        case .interfaceIsNotDefaultRoute: "Interface is not the default route"
        case .ipv4ConfigurationValid: "IPv4 configuration valid"
        case .dhcpPoolValid: "DHCP pool valid"
        case .dnsConfigurationValid: "DNS configuration valid"
        case .requiredPortsAvailable: "Required ports available"
        case .generatedConfigurationValid: "Generated configuration valid"
        }
    }

    // MARK: - Issues

    private func issues(_ report: PreflightReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Errors first: they are the ones that must be fixed before anything can start.
            ForEach(report.errors) { issue in
                issueRow(issue, systemImage: "xmark.circle.fill", tint: .red)
            }
            ForEach(report.warnings) { issue in
                issueRow(issue, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    private func issueRow(
        _ issue: PreflightIssue,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: issue.title)
                    .font(.callout.weight(.medium))
                Text(verbatim: issue.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let suggestion = issue.recoverySuggestion {
                    Text(verbatim: suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
