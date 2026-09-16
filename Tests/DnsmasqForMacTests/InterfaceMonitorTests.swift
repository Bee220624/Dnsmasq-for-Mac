import Foundation
import MacNetInterfaces
import MacNetModels
import Testing

private final class CableInterfaceEnumerator: InterfaceEnumerating, @unchecked Sendable {
    private let lock = NSLock()
    private var interfaces: [NetworkInterfaceDescriptor] = []

    func set(_ value: [NetworkInterfaceDescriptor]) { lock.withLock { interfaces = value } }
    func enumerateInterfaces() -> [NetworkInterfaceDescriptor] { lock.withLock { interfaces } }
}

@Suite("Cable interface selection") @MainActor
struct InterfaceMonitorTests {
    private func ethernet(_ name: String, connected: Bool, mac: String? = nil) -> NetworkInterfaceDescriptor {
        NetworkInterfaceDescriptor(
            bsdName: name, displayName: name, hardwarePortName: name, kind: .ethernet,
            macAddress: mac ?? "00:11:22:33:44:55", ipv4Addresses: [], isUp: true,
            isRunning: true, isLinkActive: connected, isDefaultRoute: false, isSupported: true,
            unsupportedReason: nil
        )
    }

    @Test("no cable leaves the interface unselected even when Ethernet is reported running")
    func waitsForPhysicalLink() {
        let source = CableInterfaceEnumerator()
        source.set([ethernet("en1", connected: false), ethernet("en7", connected: false)])
        let monitor = InterfaceMonitor(enumerator: source)
        monitor.refresh()
        #expect(monitor.selectedBSDName == nil)
        #expect(monitor.usesAutomaticSelection)
        #expect(monitor.connectedInterfaces.isEmpty)
    }

    @Test("plugging the cable selects the newly connected adapter without a manual refresh action")
    func followsConnectedCable() {
        let source = CableInterfaceEnumerator()
        source.set([ethernet("en1", connected: false), ethernet("en7", connected: false)])
        let monitor = InterfaceMonitor(enumerator: source)
        monitor.refresh()
        source.set([ethernet("en1", connected: false), ethernet("en7", connected: true)])
        // The dynamic-store callback invokes the same refresh entry point.
        monitor.refresh()
        #expect(monitor.selectedBSDName == "en7")
        source.set([ethernet("en1", connected: false), ethernet("en7", connected: false)])
        monitor.refresh()
        #expect(monitor.selectedBSDName == nil)
        source.set([ethernet("en1", connected: false), ethernet("en8", connected: true)])
        monitor.refresh()
        #expect(monitor.selectedBSDName == "en8")
    }

    @Test("a second connected cable requires a user choice")
    func multipleCablesNeedSelection() {
        let source = CableInterfaceEnumerator()
        source.set([ethernet("en7", connected: true)])
        let monitor = InterfaceMonitor(enumerator: source)
        monitor.refresh()
        #expect(monitor.selectedBSDName == "en7")
        source.set([ethernet("en7", connected: true), ethernet("en8", connected: true)])
        monitor.refresh()
        #expect(monitor.selectedBSDName == nil)
        #expect(monitor.connectedInterfaces.count == 2)
        monitor.select("en8")
        monitor.refresh()
        #expect(monitor.selectedBSDName == "en8")
        #expect(!monitor.usesAutomaticSelection)
    }

    @Test("manual selection is preserved until automatic detection is requested")
    func preservesManualChoice() {
        let source = CableInterfaceEnumerator()
        source.set([ethernet("en1", connected: false), ethernet("en7", connected: true)])
        let monitor = InterfaceMonitor(enumerator: source)
        monitor.refresh()
        monitor.select("en1")
        monitor.refresh()
        #expect(monitor.selectedBSDName == "en1")
        monitor.useAutomaticSelection()
        #expect(monitor.selectedBSDName == "en7")
        #expect(monitor.usesAutomaticSelection)
    }

    @Test("losing a manually selected adapter never silently chooses a neighbor")
    func removedManualAdapterStaysUnselected() {
        let source = CableInterfaceEnumerator()
        source.set([ethernet("en7", connected: true), ethernet("en8", connected: true)])
        let monitor = InterfaceMonitor(enumerator: source)
        monitor.refresh()
        monitor.select("en7")
        source.set([ethernet("en8", connected: true)])
        monitor.refresh()
        #expect(monitor.selectedBSDName == nil)
        monitor.refresh()
        #expect(monitor.selectedBSDName == nil)
        monitor.useAutomaticSelection()
        #expect(monitor.selectedBSDName == "en8")
    }

    @Test("a replacement adapter with the same BSD name does not inherit a manual selection")
    func replacementNeedsSelection() {
        let source = CableInterfaceEnumerator()
        source.set([ethernet("en7", connected: true)])
        let monitor = InterfaceMonitor(enumerator: source)
        monitor.refresh()
        monitor.select("en7")
        source.set([ethernet("en7", connected: true, mac: "aa:bb:cc:dd:ee:ff")])
        monitor.refresh()
        #expect(monitor.selectedBSDName == nil)
    }

    @Test("session lock prevents automatic and manual interface changes")
    func sessionPinsInterface() {
        let source = CableInterfaceEnumerator()
        source.set([ethernet("en7", connected: true)])
        let monitor = InterfaceMonitor(enumerator: source)
        monitor.refresh()
        monitor.updateSessionLock(isLocked: true, interfaceBSDName: "en7")
        source.set([ethernet("en8", connected: true)])
        monitor.refresh()
        monitor.select("en8")
        monitor.useAutomaticSelection()
        #expect(monitor.selectedBSDName == "en7")
        monitor.updateSessionLock(isLocked: false, interfaceBSDName: nil)
        #expect(monitor.selectedBSDName == "en8")
    }
}
