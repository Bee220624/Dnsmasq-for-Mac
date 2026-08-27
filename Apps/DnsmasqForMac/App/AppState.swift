import Foundation
import MacNetModels

/// Coarse lifecycle of the one service session the app may run (ticket §6.9).
///
/// Modelled as a single enum on purpose: the ticket forbids representing run state with
/// several independent booleans, because that admits contradictory combinations such as
/// "starting and stopped". Payload-carrying cases arrive with the session work in a later
/// phase.
enum RuntimeStatePhase: String, Sendable, Equatable, CaseIterable {
    case stopped
    case preflighting
    case starting
    case running
    case stopping
    case recovering
    case failed
}

/// Root observable state for the app process.
///
/// Phase 1 carries only what the shell needs to render. Profile, interface, and session
/// ownership are added by their own phases rather than accumulating here.
@MainActor
@Observable
final class AppState {
    /// Current service lifecycle phase. Only the session coordinator may advance this once
    /// that exists; nothing else writes it.
    private(set) var runtimePhase: RuntimeStatePhase = .stopped

    /// When the currently running session started. `nil` whenever not running.
    private(set) var sessionStartedAt: Date?

    /// Protocol version this build speaks, surfaced in Settings for support purposes.
    let protocolVersion = MacNetCoreInfo.protocolVersion

    func setRuntimePhase(_ phase: RuntimeStatePhase, startedAt: Date? = nil) {
        runtimePhase = phase
        sessionStartedAt = startedAt
    }
}
