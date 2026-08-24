import Foundation
import Testing
import MacNetModels

/// The handshake decides whether the app is willing to drive this helper at all.
@Suite("Helper service info")
struct HelperServiceInfoTests {

    private func info(protocolVersion: Int = 1, euid: UInt32 = 0) -> HelperServiceInfo {
        HelperServiceInfo(
            helperVersion: "0.1.0",
            protocolVersion: protocolVersion,
            effectiveUID: euid,
            buildType: .release,
            bundleIdentifier: "com.bee.macnetlab.helper"
        )
    }

    @Test("a root helper speaking our protocol is compatible")
    func acceptsMatchingHelper() {
        #expect(info().isCompatible(withProtocolVersion: 1))
    }

    @Test("a protocol mismatch is incompatible in both directions")
    func rejectsProtocolMismatch() {
        // Older *and* newer are both refused. A newer helper may have changed the meaning of
        // a field this app still sends, which is more dangerous than an outright failure.
        #expect(!info(protocolVersion: 0).isCompatible(withProtocolVersion: 1))
        #expect(!info(protocolVersion: 2).isCompatible(withProtocolVersion: 1))
    }

    @Test("a helper that is not root is incompatible even if the protocol matches")
    func rejectsNonRootHelper() {
        // Nothing the product does works without root, so a non-root helper is reported as
        // unusable rather than being allowed to fail later with a confusing permission error.
        #expect(!info(euid: 501).isCompatible(withProtocolVersion: 1))
    }

    @Test("round-trips through JSON")
    func roundTripsThroughJSON() throws {
        let original = info()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(HelperServiceInfo.self, from: data) == original)
    }
}
