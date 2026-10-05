import Foundation

enum ConnectionJourneyOutcome: Equatable, Sendable {
    case success
    case failure
}

enum ConnectionJourneyPhase: String, Equatable, Sendable {
    case idle
    case pressing
    case charging
    case flying
    case arriving
    case connected
    case failing
    case failed
}

struct ConnectionJourneyFrame: Equatable, Sendable {
    let phase: ConnectionJourneyPhase
    let phaseProgress: Double
    let elapsed: Double
    let flightElapsed: Double

    var isConnecting: Bool {
        switch phase {
        case .pressing, .charging, .flying, .arriving, .failing: true
        case .idle, .connected, .failed: false
        }
    }

    var isTerminal: Bool { phase == .connected || phase == .failed }
}

struct ConnectionJourney: Sendable {
    private struct Resolution: Sendable {
        let outcome: ConnectionJourneyOutcome
        let date: Date
        let failureFlightElapsed: Double?
    }

    private var startedAt: Date?
    private var resolution: Resolution?
    private var settledOutcome: ConnectionJourneyOutcome?

    mutating func begin(at date: Date = .now) {
        startedAt = date
        resolution = nil
        settledOutcome = nil
    }

    mutating func resolve(_ outcome: ConnectionJourneyOutcome, at date: Date = .now) {
        guard let startedAt else { return }
        if let resolution {
            guard resolution.outcome == .success, outcome == .failure else { return }
        }
        let eventDate = max(startedAt, date)
        let failureFlightElapsed = outcome == .failure ? frame(at: eventDate).flightElapsed : nil
        resolution = Resolution(outcome: outcome, date: eventDate, failureFlightElapsed: failureFlightElapsed)
    }

    mutating func reset() {
        startedAt = nil
        resolution = nil
        settledOutcome = nil
    }

    mutating func settle(_ outcome: ConnectionJourneyOutcome) {
        reset()
        settledOutcome = outcome
    }

    func frame(at date: Date = .now) -> ConnectionJourneyFrame {
        guard let startedAt else {
            return ConnectionJourneyFrame(
                phase: settledOutcome.map { $0 == .success ? .connected : .failed } ?? .idle,
                phaseProgress: settledOutcome == nil ? 0 : 1,
                elapsed: 0,
                flightElapsed: 0
            )
        }

        let sampleDate = max(startedAt, date)
        let elapsed = sampleDate.timeIntervalSince(startedAt)
        if let resolution {
            let endingDate = resolution.outcome == .success
                ? max(startedAt.addingTimeInterval(2.5), resolution.date)
                : resolution.date
            let endingStart = endingDate.timeIntervalSince(startedAt)
            if sampleDate >= endingDate {
                let terminal = sampleDate >= endingDate.addingTimeInterval(0.7)
                let progress = terminal ? 1 : min(1, sampleDate.timeIntervalSince(endingDate) / 0.7)
                let phase: ConnectionJourneyPhase = switch resolution.outcome {
                case .success: terminal ? .connected : .arriving
                case .failure: terminal ? .failed : .failing
                }
                return ConnectionJourneyFrame(
                    phase: phase,
                    phaseProgress: progress,
                    elapsed: min(elapsed, endingStart + 0.7),
                    flightElapsed: resolution.failureFlightElapsed ?? max(0, endingStart - 1)
                )
            }
        }

        // A pending real connection keeps cruising; elapsed animation time never implies success.
        let phase: ConnectionJourneyPhase
        let progress: Double
        if sampleDate < startedAt.addingTimeInterval(0.3) {
            phase = .pressing
            progress = min(1, elapsed / 0.3)
        } else if sampleDate < startedAt.addingTimeInterval(1) {
            phase = .charging
            progress = max(0, min(1, (elapsed - 0.3) / 0.7))
        } else {
            phase = .flying
            progress = min(1, (elapsed - 1) / 1.5)
        }
        return ConnectionJourneyFrame(
            phase: phase,
            phaseProgress: progress,
            elapsed: elapsed,
            flightElapsed: max(0, elapsed - 1)
        )
    }
}
