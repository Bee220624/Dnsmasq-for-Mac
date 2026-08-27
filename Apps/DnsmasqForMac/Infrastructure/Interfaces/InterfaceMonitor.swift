import Foundation
import MacNetInterfaces
import MacNetModels
import OSLog
import SwiftUI

/// The app's view of the machine's network interfaces, and which one the user has chosen.
///
/// Owns enumeration, change tracking, and selection. Deliberately does **not** decide whether
/// an interface may host a session — that judgment lives in `InterfaceSupportPolicy`, shared
/// with the helper so the two cannot disagree.
@MainActor
@Observable
final class InterfaceMonitor {

    private(set) var interfaces: [NetworkInterfaceDescriptor] = []

    /// BSD name of the interface the user has chosen, if any.
    private(set) var selectedBSDName: String?

    /// True once the first enumeration has completed, so the UI can tell "none found" apart
    /// from "not looked yet".
    private(set) var hasLoaded = false

    private let enumerator: any InterfaceEnumerating
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.bee.dnsmasqformac", category: "interfaces")
    private var watcher: InterfaceChangeWatcher?

    /// The specification: the most recently used interface is remembered here and **not** in the
    /// profile. A USB adapter's BSD name changes between reboots and ports, and a profile that
    /// pinned one could silently select a production port on another machine.
    private static let lastSelectedDefaultsKey = "com.bee.dnsmasqformac.lastSelectedInterface"

    init(
        enumerator: any InterfaceEnumerating = SystemInterfaceEnumerator(),
        defaults: UserDefaults = .standard
    ) {
        self.enumerator = enumerator
        self.defaults = defaults
    }

    // MARK: - Selection

    var selected: NetworkInterfaceDescriptor? {
        guard let selectedBSDName else { return nil }
        return interfaces.first { $0.bsdName == selectedBSDName }
    }

    /// Interfaces the user may choose. Refused ones are still shown in the picker, disabled
    /// and with a reason.
    var selectableInterfaces: [NetworkInterfaceDescriptor] {
        interfaces.filter(\.isSupported)
    }

    /// Records a user's choice.
    ///
    /// Refuses to select an unsupported interface. The picker already disables those rows;
    /// this is the second half of that, so a programming mistake elsewhere cannot put an
    /// unusable interface into a session request.
    func select(_ bsdName: String) {
        guard let candidate = interfaces.first(where: { $0.bsdName == bsdName }),
              candidate.isSupported
        else {
            logger.error("refused selection of unsupported interface \(bsdName, privacy: .public)")
            return
        }

        selectedBSDName = bsdName
        defaults.set(bsdName, forKey: Self.lastSelectedDefaultsKey)
    }

    // MARK: - Lifecycle

    func start() {
        refresh()

        guard watcher == nil else { return }
        let watcher = InterfaceChangeWatcher { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Re-reads the interface list and reconciles the current selection with it.
    func refresh() {
        let previous = selectedBSDName
        interfaces = enumerator.enumerateInterfaces()
        hasLoaded = true

        reconcileSelection(previouslySelected: previous)
    }

    /// Keeps the selection meaningful as hardware comes and goes.
    ///
    /// Three cases matter, and they are handled differently on purpose:
    ///
    /// * The selected interface is still usable — keep it, so a routine refresh does not move
    ///   the user's choice underneath them.
    /// * It disappeared, or became unusable — clear the selection rather than silently sliding
    ///   to a neighbour. The specification forbids auto-selecting Wi-Fi or the default route, and
    ///   quietly moving a selection is how a user ends up serving the wrong port.
    /// * Nothing was selected — offer a default, which may legitimately be nothing.
    private func reconcileSelection(previouslySelected: String?) {
        if let previouslySelected,
           let current = interfaces.first(where: { $0.bsdName == previouslySelected }) {
            if current.isSupported { return }

            logger.log(
                """
                clearing selection: \(previouslySelected, privacy: .public) \
                is no longer usable
                """
            )
            selectedBSDName = nil
        } else if previouslySelected != nil {
            logger.log("clearing selection: \(previouslySelected ?? "", privacy: .public) is gone")
            selectedBSDName = nil
        }

        guard selectedBSDName == nil else { return }

        let remembered = defaults.string(forKey: Self.lastSelectedDefaultsKey)
        selectedBSDName = InterfaceSupportPolicy.defaultSelection(
            from: interfaces, preferring: remembered
        )?.bsdName
    }
}
