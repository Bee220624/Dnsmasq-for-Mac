import Foundation
import MacNetModels
import MacNetXPC
import OSLog
import SwiftUI

/// Drives preflight, start, and stop from the UI (ticket §15–§17).
///
/// Holds no policy of its own. Every decision that matters — whether an interface may be used,
/// whether a configuration is valid, whether a port is free — is made by the helper, on data it
/// gathered itself. What lives here is the *presentation* of that: which button is enabled,
/// what the user is told, and when the isolation confirmation resets.
@MainActor
@Observable
final class SessionController {

    private(set) var phase: RuntimeStatePhase = .stopped
    private(set) var activeSession: ActiveSession?
    private(set) var preflightReport: PreflightReport?
    private(set) var lastFailure: ServiceFailure?

    /// Warnings from a recovery that ran on connect. Cleared once acknowledged.
    private(set) var recoveryWarnings: [String] = []

    /// The user's confirmation that the selected interface is isolated (ticket §5.3.5).
    ///
    /// Deliberately a plain property on a view model: it is never persisted, never written to a
    /// profile, and does not survive a relaunch. `reset()` is called on stop, on interface
    /// change, and on any DHCP pool change, so a confirmation can never outlive the thing it
    /// was given about.
    var isolationConfirmed = false

    private let client: HelperClient
    private let logger = Logger(subsystem: "com.bee.macnetlab", category: "session-controller")

    init(client: HelperClient) {
        self.client = client
    }

    // MARK: - Derived state

    var isRunning: Bool { phase == .running }
    var isBusy: Bool { phase.isTransitioning }

    /// Whether the isolation confirmation is required for this configuration.
    ///
    /// Only DHCP can disrupt a network the user did not intend to serve. Requiring the
    /// confirmation for a DNS-only session would be friction with no safety value.
    func requiresIsolationConfirmation(for profile: NetworkProfile) -> Bool {
        profile.dhcpConfiguration.enabled
    }

    /// Whether Start may be offered.
    ///
    /// The helper refuses anything unsafe regardless of what this returns — this only decides
    /// whether the button looks available. Both layers matter: the helper for correctness, this
    /// for not presenting an action that will certainly fail.
    func canStart(profile: NetworkProfile?, hasInterface: Bool, helperReady: Bool) -> Bool {
        guard let profile, helperReady, hasInterface, !isBusy, !isRunning else { return false }
        if requiresIsolationConfirmation(for: profile) && !isolationConfirmed { return false }
        if let report = preflightReport, report.hasBlockingIssues { return false }
        return true
    }

    /// Resets the confirmation (ticket §5.3.5).
    ///
    /// Called whenever the thing being confirmed changes. A confirmation given about one
    /// interface and pool must never carry over to a different one.
    func resetIsolationConfirmation() {
        guard isolationConfirmed else { return }
        logger.log("isolation confirmation reset")
        isolationConfirmed = false
    }

    func clearFailure() { lastFailure = nil }
    func acknowledgeRecoveryWarnings() { recoveryWarnings = [] }

    // MARK: - Reconnection

    /// Re-adopts whatever the helper is already doing (ticket §17.1).
    ///
    /// The app can be force-quit while a session runs; the helper and dnsmasq keep going. On
    /// relaunch the app must show what is actually happening rather than an empty Stopped
    /// state, or the user would have no way to stop it from the UI.
    func synchronize() async {
        do {
            let state = try await client.runtimeStatus()
            apply(state)

            if case .stopped = state {
                // Reconcile anything a previous run left behind before offering Start.
                let report = try await client.recoverStaleState()
                if report.outcome != .nothingToRecover {
                    logger.log("recovery on connect: \(report.outcome.rawValue, privacy: .public)")
                    recoveryWarnings = report.warnings
                }
            }
        } catch {
            // Not surfaced as a failure: the helper may simply not be installed yet, which the
            // helper-status UI already explains far better than an error here would.
            logger.log("could not synchronize with the helper: \(error.message, privacy: .public)")
            phase = .stopped
            activeSession = nil
        }
    }

    private func apply(_ state: RuntimeState) {
        switch state {
        case .stopped:
            phase = .stopped
            activeSession = nil
        case .preflighting:
            phase = .preflighting
        case .starting:
            phase = .starting
        case .running(let session):
            phase = .running
            activeSession = session
            // A session that is already running was confirmed when it started; leaving this
            // false would make Stop look unavailable.
            isolationConfirmed = true
        case .stopping:
            phase = .stopping
        case .recovering:
            phase = .recovering
        case .failed(let failure):
            phase = .failed
            lastFailure = failure
            activeSession = nil
        }
    }

    // MARK: - Preflight

    func runPreflight(_ request: SessionStartRequest) async {
        guard !isBusy else { return }
        phase = .preflighting
        defer { phase = isRunning ? .running : .stopped }

        do {
            preflightReport = try await client.preflight(request)
            lastFailure = nil
        } catch {
            preflightReport = nil
            lastFailure = error
        }
    }

    // MARK: - Start and stop

    func start(_ request: SessionStartRequest) async {
        guard !isBusy, !isRunning else { return }
        phase = .starting
        lastFailure = nil

        do {
            let session = try await client.startSession(request)
            activeSession = session
            phase = .running
            logger.log("session \(session.id.uuidString, privacy: .public) started")
        } catch {
            // The helper rolls back before reporting, so on this path the machine is already
            // back to how it was — with one exception, `cleanupFailed`, which the error itself
            // explains and which the UI shows prominently.
            lastFailure = error
            phase = error.code == .cleanupFailed ? .failed : .stopped
            activeSession = nil
        }
    }

    func stop() async {
        guard let session = activeSession, !isBusy else { return }
        phase = .stopping

        do {
            try await client.stopSession(id: session.id)
            activeSession = nil
            phase = .stopped
            // Ticket §5.3.5: the confirmation does not survive the session it was given for.
            isolationConfirmed = false
            logger.log("session \(session.id.uuidString, privacy: .public) stopped")
        } catch {
            lastFailure = error
            if error.code == .cleanupFailed {
                // The user's Mac may still hold an address. This must stay visible rather than
                // collapsing back to a tidy Stopped.
                phase = .failed
            } else {
                activeSession = nil
                phase = .stopped
                isolationConfirmed = false
            }
        }
    }
}
