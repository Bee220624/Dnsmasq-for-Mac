import Foundation
import MacNetModels
import MacNetXPC

protocol SessionClient: Sendable {
    func runtimeStatus() async throws(ServiceFailure) -> RuntimeState
    func recoverStaleState() async throws(ServiceFailure) -> RecoveryReport
    func preflight(_ request: SessionStartRequest) async throws(ServiceFailure) -> PreflightReport
    func startSession(_ request: SessionStartRequest) async throws(ServiceFailure) -> ActiveSession
    func stopSession(id: UUID) async throws(ServiceFailure)
}
