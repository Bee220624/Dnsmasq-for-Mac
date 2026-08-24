import Foundation
import OSLog
import SystemConfiguration

/// Notifies when the machine's network configuration changes.
///
/// Watches the dynamic store keys listed in ticket §12.2 — per-interface IPv4 and link state,
/// plus the global IPv4 and IPv6 entities, which is how a change of default route shows up.
///
/// If registering for notifications fails, it falls back to polling every two seconds. Ticket
/// §12.2 requires that the two never run at the same time: doing both would double the work
/// and, worse, make an intermittent notification failure invisible during development.
final class InterfaceChangeWatcher: @unchecked Sendable {

    /// How the watcher is currently learning about changes. Surfaced so a fallback to polling
    /// is visible rather than silently degrading.
    enum Mode: String, Sendable {
        case notifications
        case polling
        case stopped
    }

    private let logger = Logger(subsystem: "com.bee.macnetlab", category: "interface-watcher")
    private let queue = DispatchQueue(label: "com.bee.macnetlab.interface-watcher")
    private let onChange: @Sendable () -> Void

    private var store: SCDynamicStore?
    private var pollingTimer: (any DispatchSourceTimer)?
    private var mode: Mode = .stopped

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        // Safe from any thread: both teardown paths only touch objects owned by this instance.
        pollingTimer?.cancel()
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }

    func start() {
        queue.async { [self] in
            guard mode == .stopped else { return }

            if startNotifications() {
                mode = .notifications
                logger.log("watching network configuration via SCDynamicStore")
            } else {
                startPolling()
                mode = .polling
                logger.error("SCDynamicStore notifications unavailable; polling every 2s")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            pollingTimer?.cancel()
            pollingTimer = nil
            if let store {
                SCDynamicStoreSetDispatchQueue(store, nil)
                self.store = nil
            }
            mode = .stopped
        }
    }

    // MARK: - Notifications

    private func startNotifications() -> Bool {
        // The callback is a C function pointer and cannot capture, so the instance is passed
        // through the store's context as an unretained pointer. Unretained is correct: the
        // store never outlives this object, because `deinit` detaches it first.
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let watcher = Unmanaged<InterfaceChangeWatcher>.fromOpaque(info)
                .takeUnretainedValue()
            watcher.onChange()
        }

        guard let store = SCDynamicStoreCreate(
            nil,
            "com.bee.macnetlab.interface-watcher" as CFString,
            callback,
            &context
        ) else { return false }

        // Patterns rather than exact keys: interfaces come and go, and a USB adapter appearing
        // is precisely the event this needs to catch.
        let patterns = [
            "State:/Network/Interface/.*/IPv4",
            "State:/Network/Interface/.*/Link",
        ] as CFArray

        let globalKeys = [
            SCDynamicStoreKeyCreateNetworkGlobalEntity(
                nil, kSCDynamicStoreDomainState, kSCEntNetIPv4
            ),
            SCDynamicStoreKeyCreateNetworkGlobalEntity(
                nil, kSCDynamicStoreDomainState, kSCEntNetIPv6
            ),
        ] as CFArray

        guard SCDynamicStoreSetNotificationKeys(store, globalKeys, patterns) else {
            return false
        }
        guard SCDynamicStoreSetDispatchQueue(store, queue) else {
            return false
        }

        self.store = store
        return true
    }

    // MARK: - Polling fallback

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Two seconds with generous leeway: this is a fallback for a case that should not
        // happen, and it must not become a reason the app spins the CPU while idle
        // (ticket §25 targets under 1% while stopped).
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2), leeway: .milliseconds(500))
        timer.setEventHandler { [onChange] in onChange() }
        timer.resume()
        pollingTimer = timer
    }
}
