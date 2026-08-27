import Foundation
import MacNetModels
import MacNetXPC
import OSLog
import SwiftUI

/// Supplies the Leases page with what the helper knows.
///
/// ## Two different clocks, on purpose
///
/// The lease *set* changes rarely — when a device appears or renews — and is fetched from the
/// helper, which is watching the file and only has something new when there genuinely is.
///
/// The *time remaining* column changes every second, and is recomputed locally from expiry
/// timestamps already in hand. The specification is explicit about this split: re-reading the file
/// once a second to animate a countdown would spend the whole session doing work that changes
/// nothing.
@MainActor
@Observable
final class LeaseMonitor {

    private(set) var leases: [DHCPLease] = []
    private(set) var lastReadAt: Date?
    private(set) var malformedLineCount = 0

    /// Ticks once a second so the remaining-time column stays live.
    ///
    /// Views read this rather than calling `Date()` themselves, which keeps every row on the
    /// same instant and makes the whole table one invalidation instead of one per row.
    private(set) var now = Date()

    private let client: HelperClient
    private let logger = Logger(subsystem: "com.bee.dnsmasqformac", category: "leases")

    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var sessionID: UUID?

    init(client: HelperClient) {
        self.client = client
    }

    // MARK: - Lifecycle

    func start(sessionID: UUID) {
        guard self.sessionID != sessionID else { return }
        stop()
        self.sessionID = sessionID

        // Two seconds is the target in the specification for a lease appearing on screen. The helper
        // does the actual watching; this only asks whether its snapshot has moved on.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.now = Date() }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        tickTask?.cancel()
        pollTask = nil
        tickTask = nil
        sessionID = nil
        leases = []
        lastReadAt = nil
        malformedLineCount = 0
    }

    func refresh() async {
        guard let sessionID else { return }
        do {
            let snapshot = try await client.leaseSnapshot(sessionID: sessionID)
            leases = snapshot.leases
            lastReadAt = snapshot.readAt
            malformedLineCount = snapshot.malformedLineCount
        } catch {
            // Not surfaced. A dropped connection is already reported by the session controller,
            // and an error banner over the lease table would say the same thing twice.
            logger.debug("lease snapshot unavailable: \(error.message, privacy: .public)")
        }
    }
}
