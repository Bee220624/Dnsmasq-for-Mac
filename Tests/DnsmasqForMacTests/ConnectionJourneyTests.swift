import Foundation
import Testing

@Suite("Connection animation journey")
struct ConnectionJourneyTests {
    private let origin = Date(timeIntervalSinceReferenceDate: 0)

    @Test("an untouched or reset journey remains idle")
    func idleAndReset() {
        var journey = ConnectionJourney()
        let idle = journey.frame(at: origin)
        #expect(idle.phase == .idle)
        #expect(idle.elapsed == 0)
        #expect(!idle.isConnecting)
        #expect(!idle.isTerminal)
        journey.resolve(.success, at: origin)
        #expect(journey.frame(at: origin.addingTimeInterval(100)) == idle)
        journey.begin(at: origin)
        journey.resolve(.failure, at: origin.addingTimeInterval(1.5))
        journey.reset()
        #expect(journey.frame(at: origin.addingTimeInterval(100)) == idle)
    }

    @Test("the opening stages honor their timing boundaries", arguments: [
        (0.0, ConnectionJourneyPhase.pressing),
        (0.299, .pressing),
        (0.3, .charging),
        (0.999, .charging),
        (1.0, .flying),
        (2.5, .flying)
    ])
    func openingStages(elapsed: Double, expected: ConnectionJourneyPhase) {
        var journey = ConnectionJourney()
        journey.begin(at: origin)
        let frame = journey.frame(at: origin.addingTimeInterval(elapsed))
        #expect(frame.phase == expected)
        #expect(frame.isConnecting)
        #expect((0...1).contains(frame.phaseProgress))
    }

    @Test("fast success preserves the flight before arriving")
    func earlySuccess() {
        var journey = ConnectionJourney()
        journey.begin(at: origin)
        journey.resolve(.success, at: origin.addingTimeInterval(0.1))
        #expect(journey.frame(at: origin.addingTimeInterval(0.2)).phase == .pressing)
        #expect(journey.frame(at: origin.addingTimeInterval(2.499)).phase == .flying)
        let arriving = journey.frame(at: origin.addingTimeInterval(2.5))
        #expect(arriving.phase == .arriving)
        #expect(arriving.phaseProgress == 0)
        #expect(arriving.flightElapsed == 1.5)
        #expect(journey.frame(at: origin.addingTimeInterval(3.199)).phase == .arriving)
        #expect(journey.frame(at: origin.addingTimeInterval(3.2)).phase == .connected)
    }

    @Test("animation completion cannot report success before the service replies")
    func pendingConnectionKeepsCruising() {
        var journey = ConnectionJourney()
        journey.begin(at: origin)
        let waiting = journey.frame(at: origin.addingTimeInterval(60))
        #expect(waiting.phase == .flying)
        #expect(waiting.phaseProgress == 1)
        #expect(waiting.flightElapsed == 59)
        #expect(!waiting.isTerminal)
        journey.resolve(.success, at: origin.addingTimeInterval(60))
        #expect(journey.frame(at: origin.addingTimeInterval(60)).phase == .arriving)
        let terminal = journey.frame(at: origin.addingTimeInterval(61))
        #expect(terminal.phase == .connected)
        #expect(terminal.isTerminal)
        #expect(!terminal.isConnecting)
        #expect(terminal.flightElapsed == 59)
        #expect(journey.frame(at: origin.addingTimeInterval(600)) == terminal)
    }

    @Test("failure interrupts any stage and freezes its flight origin", arguments: [0.1, 0.5, 1.8, 12.0])
    func failureInterrupts(elapsed: Double) {
        var journey = ConnectionJourney()
        journey.begin(at: origin)
        journey.resolve(.failure, at: origin.addingTimeInterval(elapsed))
        let failure = journey.frame(at: origin.addingTimeInterval(elapsed))
        #expect(failure.phase == .failing)
        #expect(failure.phaseProgress == 0)
        #expect(failure.flightElapsed == max(0, elapsed - 1))
        let collapsing = journey.frame(at: origin.addingTimeInterval(elapsed + 0.35))
        #expect(collapsing.phase == .failing)
        #expect(abs(collapsing.phaseProgress - 0.5) < 0.000_001)
        #expect(collapsing.flightElapsed == failure.flightElapsed)
        let failed = journey.frame(at: origin.addingTimeInterval(elapsed + 0.701))
        #expect(failed.phase == .failed)
        #expect(failed.isTerminal)
        #expect(failed.flightElapsed == failure.flightElapsed)
    }

    @Test("service failure overrides early success during opening, arrival, or connected state", arguments: [0.5, 2.8, 4.0])
    func failureSupersedesSuccess(failureElapsed: Double) {
        var journey = ConnectionJourney()
        journey.begin(at: origin)
        journey.resolve(.success, at: origin.addingTimeInterval(0.1))
        let failureDate = origin.addingTimeInterval(failureElapsed)
        let previousFlight = journey.frame(at: failureDate).flightElapsed
        journey.resolve(.failure, at: failureDate)
        let failing = journey.frame(at: failureDate)
        #expect(failing.phase == .failing)
        #expect(failing.phaseProgress == 0)
        #expect(failing.flightElapsed == previousFlight)
        #expect(journey.frame(at: failureDate.addingTimeInterval(0.7)).phase == .failed)
        #expect(journey.frame(at: origin.addingTimeInterval(10)).phase == .failed)
    }

    @Test("a success callback cannot replace a known service failure")
    func successCannotOverrideFailure() {
        var journey = ConnectionJourney()
        journey.begin(at: origin)
        journey.resolve(.failure, at: origin.addingTimeInterval(1.5))
        journey.resolve(.success, at: origin.addingTimeInterval(1.6))
        #expect(journey.frame(at: origin.addingTimeInterval(1.6)).phase == .failing)
        #expect(journey.frame(at: origin.addingTimeInterval(10)).phase == .failed)
    }

    @Test("duplicate result callbacks preserve the original transition time", arguments: [
        ConnectionJourneyOutcome.success, .failure
    ])
    func duplicateResultsPreserveTiming(outcome: ConnectionJourneyOutcome) {
        var journey = ConnectionJourney()
        journey.begin(at: origin)
        journey.resolve(outcome, at: origin.addingTimeInterval(3))
        let sampleDate = origin.addingTimeInterval(3.4)
        let frame = journey.frame(at: sampleDate)
        journey.resolve(outcome, at: sampleDate)
        #expect(journey.frame(at: sampleDate) == frame)
        #expect(journey.frame(at: origin.addingTimeInterval(3.7)).isTerminal)
    }

    @Test("a retry starts a fresh journey after failure")
    func retry() {
        var journey = ConnectionJourney()
        journey.begin(at: origin)
        journey.resolve(.failure, at: origin.addingTimeInterval(1))
        let retryDate = origin.addingTimeInterval(10)
        journey.begin(at: retryDate)
        #expect(journey.frame(at: retryDate).phase == .pressing)
        #expect(journey.frame(at: retryDate).elapsed == 0)
        journey.resolve(.success, at: retryDate.addingTimeInterval(0.2))
        #expect(journey.frame(at: retryDate.addingTimeInterval(3.2)).phase == .connected)
    }

    @Test("existing service state is displayed without replaying a journey", arguments: [
        ConnectionJourneyOutcome.success, .failure
    ])
    func settledState(outcome: ConnectionJourneyOutcome) {
        var journey = ConnectionJourney()
        journey.begin(at: origin)
        journey.settle(outcome)
        let frame = journey.frame(at: origin)
        #expect(frame.phase == (outcome == .success ? .connected : .failed))
        #expect(frame.phaseProgress == 1)
        #expect(frame.elapsed == 0)
        #expect(frame.flightElapsed == 0)
        #expect(journey.frame(at: origin.addingTimeInterval(100)) == frame)
    }

    @Test("clock samples before the start clamp to the beginning")
    func earlierClockSample() {
        var journey = ConnectionJourney()
        journey.begin(at: origin)
        let frame = journey.frame(at: origin.addingTimeInterval(-1))
        #expect(frame.phase == .pressing)
        #expect(frame.phaseProgress == 0)
        #expect(frame.elapsed == 0)
        journey.resolve(.failure, at: origin.addingTimeInterval(-1))
        #expect(journey.frame(at: origin).phase == .failing)
    }

    @Test("date precision keeps stage progress bounded at an exact transition")
    func realDatePrecision() {
        let start = Date(timeIntervalSince1970: 1_760_000_000.123)
        var journey = ConnectionJourney()
        journey.begin(at: start)
        let charging = journey.frame(at: start.addingTimeInterval(0.3))
        #expect(charging.phase == .charging)
        #expect((0...1).contains(charging.phaseProgress))
        let failureDate = start.addingTimeInterval(1.75)
        journey.resolve(.failure, at: failureDate)
        #expect(journey.frame(at: failureDate.addingTimeInterval(0.7)).phase == .failed)
    }
}
