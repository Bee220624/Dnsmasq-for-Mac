import Foundation
import MacNetModels
import OSLog
import SwiftUI

/// Drives every piece of helper-related UI: Settings, onboarding, and the gate that keeps
/// Start unavailable until the helper is genuinely usable.
@MainActor
@Observable
final class HelperStatusModel {

    private(set) var readiness: HelperReadiness = .checking

    /// Set while an install or uninstall is in flight, so the UI can disable its buttons
    /// instead of letting the user queue up duplicate registrations.
    private(set) var isBusy = false

    /// Shared with `SessionController` so both speak to the same connection.
    ///
    /// One client, not two: a second `NSXPCConnection` would mean the helper serving two peers
    /// that each believe they own the session state.
    let client: HelperClient

    private let logger = Logger(subsystem: "com.bee.dnsmasqformac", category: "helper-status")

    /// Polls while the user is away approving the daemon in System Settings.
    private var approvalWatcher: Task<Void, Never>?

    init(environment: AppEnvironment) {
        client = HelperClient(environment: environment)
    }

    // No deinit cancels `approvalWatcher`: a deinit on a @MainActor type is nonisolated and
    // cannot touch isolated state. It is not needed — the watcher holds only a weak reference,
    // so once this model is released the loop returns on its next tick.

    // MARK: - Status

    func refresh() async {
        let installation = await client.installationState()

        guard installation.isConnectable else {
            readiness = .notInstalled(installation)
            // Approval is the one state that resolves without any further action from us, so
            // it is the only one worth watching for.
            if installation == .requiresApproval {
                startWatchingForApproval()
            } else {
                stopWatchingForApproval()
            }
            return
        }

        stopWatchingForApproval()
        readiness = .connecting
        readiness = await client.handshake()
        logIfIncompatible()
    }

    private func logIfIncompatible() {
        if case .incompatible(let info, let reason) = readiness {
            logger.error(
                """
                helper is unusable: \(reason, privacy: .public) \
                (helper protocol \(info.protocolVersion, privacy: .public), \
                euid \(info.effectiveUID, privacy: .public))
                """
            )
        }
    }

    // MARK: - Actions

    func install() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let state = try await client.install()
            logger.log("install produced state \(String(describing: state), privacy: .public)")
        } catch {
            readiness = .failed(error)
            return
        }
        await refresh()
    }

    func uninstall() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await client.uninstall()
        } catch {
            readiness = .failed(error)
            return
        }
        await refresh()
    }

    func openLoginItemsSettings() {
        client.openLoginItemsSettings()
    }

    // MARK: - Approval watching

    /// Re-checks status on a slow timer while approval is pending.
    ///
    /// `SMAppService` publishes no change notification, so polling is the only option. Ticket
    /// §10.2 is explicit that the app must not respond to `requiresApproval` by calling
    /// `register()` again in a loop — this only reads the status and stops as soon as it
    /// changes.
    private func startWatchingForApproval() {
        guard approvalWatcher == nil else { return }
        logger.log("watching for helper approval")

        approvalWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }

                let state = await self.client.installationState()
                if state != .requiresApproval {
                    self.logger.log("helper approval state changed; refreshing")
                    await self.refresh()
                    return
                }
            }
        }
    }

    private func stopWatchingForApproval() {
        approvalWatcher?.cancel()
        approvalWatcher = nil
    }
}
