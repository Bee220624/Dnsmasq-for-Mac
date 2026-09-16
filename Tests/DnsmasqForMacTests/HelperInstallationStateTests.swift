import ServiceManagement
import Testing

@Suite("Helper installation state")
struct HelperInstallationStateTests {
    @Test("a not-found service with bundled files still offers installation")
    func completeBundleCanRegister() {
        #expect(HelperInstallationState(status: .notFound, bundledHelperAvailable: true) == .notRegistered)
    }

    @Test("a not-found service with missing files reports an incomplete bundle")
    func missingFilesRequireReinstall() {
        #expect(HelperInstallationState(status: .notFound, bundledHelperAvailable: false) == .bundleIncomplete)
    }

    @Test("pending system approval never offers repeated registration")
    func approvalStateIsPreserved() {
        #expect(HelperInstallationState(status: .requiresApproval, bundledHelperAvailable: true) == .requiresApproval)
    }
}
