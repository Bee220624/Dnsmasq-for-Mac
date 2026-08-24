import Testing
import MacNetModels

/// Contract checks that must hold for the app and helper to be able to talk to each other
/// at all. Real lifecycle coverage against injected fakes arrives with Phase 7.
@Suite("Core contract")
struct CoreContractTests {

    /// The helper refuses to serve a client reporting a different protocol version, so a
    /// silent drift between the constant and the build setting would break every install.
    /// Config/Identifiers.xcconfig is the source of truth; this pins the Swift mirror to it.
    @Test("protocol version matches the value published in Identifiers.xcconfig")
    func protocolVersionIsPinned() {
        #expect(MacNetCoreInfo.protocolVersion == 1)
    }

    @Test("persisted schema version is pinned")
    func schemaVersionIsPinned() {
        #expect(MacNetCoreInfo.schemaVersion == 1)
    }
}
