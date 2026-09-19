import Foundation
import MacNetModels
import MacNetXPC
import MacNetValidation
import OSLog
import SwiftUI

/// Drives preflight, start, and stop from the UI (–).
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

    /// The user's confirmation that the selected interface is isolated.
    ///
    /// Deliberately a plain property on a view model: it is never persisted, never written to a
    /// profile, and does not survive a relaunch. `reset()` is called on stop, on interface
    /// change, and on any DHCP pool change, so a confirmation can never outlive the thing it
    /// was given about.
    var isolationConfirmed = false

    private let client: any SessionClient
    private var localOperationInProgress = false
    private var operationGeneration = 0
    private var needsRecovery = true
    private var runtimeIsKnown = false
    private let logger = Logger(subsystem: "com.bee.dnsmasqformac", category: "session-controller")

    init(client: any SessionClient) {
        self.client = client
    }

    // MARK: - Derived state

    var isRunning: Bool { phase == .running }
    var isBusy: Bool { phase.isTransitioning }

    /// Removal is offered only after synchronization confirmed stopped state and cleanup.
    var canRemoveHelper: Bool {
        runtimeIsKnown && !needsRecovery && !localOperationInProgress && phase == .stopped
            && activeSession == nil && lastFailure?.code != .cleanupFailed
    }

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
        guard let profile, helperReady, hasInterface, !isBusy, activeSession == nil,
              lastFailure?.code != .cleanupFailed,
              !ConfigurationValidator.hasBlockingIssues(ConfigurationValidator.validate(profile))
        else { return false }
        if requiresIsolationConfirmation(for: profile) && !isolationConfirmed { return false }
        if let report = preflightReport, report.hasBlockingIssues { return false }
        return true
    }

    /// Resets the confirmation.
    ///
    /// Called whenever the thing being confirmed changes. A confirmation given about one
    /// interface and pool must never carry over to a different one.
    func resetIsolationConfirmation() {
        guard isolationConfirmed else { return }
        logger.log("isolation confirmation reset")
        isolationConfirmed = false
    }

    func configurationChanged() {
        preflightReport = nil
        resetIsolationConfirmation()
    }

    func clearFailure() {
        if lastFailure?.code != .cleanupFailed { lastFailure = nil }
    }
    func acknowledgeRecoveryWarnings() { recoveryWarnings = [] }

    // MARK: - Reconnection

    /// Re-adopts whatever the helper is already doing.
    ///
    /// The app can be force-quit while a session runs; the helper and dnsmasq keep going. On
    /// relaunch the app must show what is actually happening rather than an empty Stopped
    /// state, or the user would have no way to stop it from the UI.
    func synchronize() async {
        guard !localOperationInProgress else { return }
        let generation = operationGeneration
        do {
            let state = try await client.runtimeStatus()
            guard !localOperationInProgress, generation == operationGeneration else { return }
            apply(state)

            if case .stopped = state, needsRecovery {
                // Reconcile anything a previous run left behind before offering Start.
                let report = try await client.recoverStaleState()
                guard !localOperationInProgress, generation == operationGeneration else { return }
                let cleanupIsIncomplete = report.outcome == .cleanupIncomplete
                    || report.outcome == .staleSessionRequiresAttention
                needsRecovery = cleanupIsIncomplete
                if report.outcome != .nothingToRecover {
                    logger.log("recovery on connect: \(report.outcome.rawValue, privacy: .public)")
                    recoveryWarnings = report.warnings
                }
                if let recovered = report.recoveredSession { apply(.running(recovered)) }
                if cleanupIsIncomplete {
                    lastFailure = ServiceFailure(code: .cleanupFailed, title: "Cleanup Required",
                                                 message: report.warnings.joined(separator: "\n"), isRetryable: true)
                    phase = .failed
                }
            }
            runtimeIsKnown = true
        } catch {
            guard !localOperationInProgress, generation == operationGeneration else { return }
            runtimeIsKnown = false
            needsRecovery = true
            // Not surfaced as a failure: the helper may simply not be installed yet, which the
            // helper-status UI already explains far better than an error here would.
            logger.log("could not synchronize with the helper: \(error.message, privacy: .public)")
            if activeSession != nil {
                lastFailure = error
                phase = .failed
            }
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
            if failure.code != .cleanupFailed { activeSession = nil }
        }
    }

    // MARK: - Preflight

    func runPreflight(_ request: SessionStartRequest) async {
        guard !isBusy, activeSession == nil, lastFailure?.code != .cleanupFailed else { return }
        localOperationInProgress = true
        operationGeneration += 1
        defer { localOperationInProgress = false }
        phase = .preflighting
        defer { phase = .stopped }

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
        guard !isBusy, !isRunning, lastFailure?.code != .cleanupFailed else { return }
        localOperationInProgress = true
        operationGeneration += 1
        defer { localOperationInProgress = false }
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
        guard !isBusy else { return }
        localOperationInProgress = true
        operationGeneration += 1
        defer { localOperationInProgress = false }
        let stoppingSession = activeSession
        phase = .stopping

        do {
            if let stoppingSession {
                try await client.stopSession(id: stoppingSession.id)
            } else {
                let report = try await client.recoverStaleState()
                if let recovered = report.recoveredSession {
                    activeSession = recovered
                    try await client.stopSession(id: recovered.id)
                } else if report.outcome == .cleanupIncomplete || report.outcome == .staleSessionRequiresAttention {
                    throw ServiceFailure(code: .cleanupFailed, title: "Cleanup Required",
                                         message: report.warnings.joined(separator: "\n"), isRetryable: true)
                }
            }
            activeSession = nil
            phase = .stopped
            runtimeIsKnown = true
            needsRecovery = false
            lastFailure = nil
            preflightReport = nil
            recoveryWarnings = []
            // The specification: the confirmation does not survive the session it was given for.
            isolationConfirmed = false
            logger.log("session stopped")
        } catch {
            lastFailure = (error as? ServiceFailure) ?? ServiceFailure.internalError("\(error)")
            // An XPC error is not evidence that the root process stopped. Keep the retry path.
            phase = .failed
        }
    }

    func monitorStatus() async {
        while !Task.isCancelled {
            await synchronize()
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }
}
