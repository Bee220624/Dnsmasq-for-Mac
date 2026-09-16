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
    private(set) var usesAutomaticSelection = true
    private(set) var selectionIsLocked = false
    private var selectedMACAddress: String?

    private let enumerator: any InterfaceEnumerating
    private let logger = Logger(subsystem: "com.bee.dnsmasqformac", category: "interfaces")
    private var watcher: InterfaceChangeWatcher?

    init(
        enumerator: any InterfaceEnumerating = SystemInterfaceEnumerator()
    ) {
        self.enumerator = enumerator
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

    var connectedInterfaces: [NetworkInterfaceDescriptor] {
        InterfaceSupportPolicy.connectedEthernetInterfaces(from: interfaces)
    }

    /// Records a user's choice.
    ///
    /// Refuses to select an unsupported interface. The picker already disables those rows;
    /// this is the second half of that, so a programming mistake elsewhere cannot put an
    /// unusable interface into a session request.
    func select(_ bsdName: String) {
        guard !selectionIsLocked,
              let candidate = interfaces.first(where: { $0.bsdName == bsdName }),
              candidate.isSupported
        else {
            logger.error("refused selection of unsupported interface \(bsdName, privacy: .public)")
            return
        }

        selectedBSDName = bsdName
        selectedMACAddress = candidate.macAddress
        usesAutomaticSelection = false
    }

    func useAutomaticSelection() {
        guard !selectionIsLocked else { return }
        usesAutomaticSelection = true
        refresh()
    }

    func updateSessionLock(isLocked: Bool, interfaceBSDName: String?) {
        selectionIsLocked = isLocked
        if isLocked {
            if let interfaceBSDName { selectedBSDName = interfaceBSDName }
        } else {
            reconcileSelection()
        }
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
        interfaces = enumerator.enumerateInterfaces()
        hasLoaded = true

        reconcileSelection()
    }

    /// Automatic mode follows live links; a manual choice stays pinned until it disappears.
    private func reconcileSelection() {
        guard !selectionIsLocked else { return }
        if !usesAutomaticSelection {
            if let current = selected, current.isSupported, current.macAddress == selectedMACAddress {
                return
            }
            // Do not silently replace a manually selected adapter with a different device.
            selectedBSDName = nil
            selectedMACAddress = nil
            return
        }
        let candidate = InterfaceSupportPolicy.defaultSelection(from: interfaces)
        selectedBSDName = candidate?.bsdName
        selectedMACAddress = candidate?.macAddress
    }
}
