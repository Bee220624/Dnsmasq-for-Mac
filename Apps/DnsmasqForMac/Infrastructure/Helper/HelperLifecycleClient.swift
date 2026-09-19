import Foundation
import MacNetModels
import MacNetXPC

/// Shared app-facing boundary; production uses the signature-pinned HelperClient.
protocol HelperLifecycleClient: SessionClient {
    func installationState() async -> HelperInstallationState
    func install() async throws(ServiceFailure) -> HelperInstallationState
    func uninstall() async throws(ServiceFailure)
    func handshake() async -> HelperReadiness
    func openLoginItemsSettings()
    func leaseSnapshot(sessionID: UUID) async throws(ServiceFailure) -> LeaseSnapshot
    func logSnapshot(sessionID: UUID, after sequence: Int64) async throws(ServiceFailure) -> LogBatch
}
