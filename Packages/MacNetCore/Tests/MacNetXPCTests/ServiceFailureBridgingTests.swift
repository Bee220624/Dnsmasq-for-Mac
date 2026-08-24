import Foundation
import Testing
import MacNetModels

/// The XPC interface is Objective-C, so every failure crosses as an `NSError`. If that bridge
/// loses information, the app can only show a generic message for problems the helper
/// diagnosed precisely — which is the difference between "something went wrong" and
/// "UDP 67 is already in use by another process".
@Suite("ServiceFailure NSError bridging")
struct ServiceFailureBridgingTests {

    @Test("round-trips every field")
    func roundTripsEveryField() throws {
        let original = ServiceFailure(
            code: .portInUse,
            title: "Port In Use",
            message: "UDP port 67 is already in use.",
            recoverySuggestion: "Stop the other DHCP server and try again.",
            technicalDetails: "bind() returned EADDRINUSE",
            isRetryable: true
        )

        let recovered = try #require(ServiceFailure.from(nsError: original.asNSError))
        #expect(recovered == original)
    }

    @Test("round-trips a failure with no optional fields")
    func roundTripsSparseFailure() throws {
        let original = ServiceFailure(
            code: .interfaceIsWiFi,
            title: "Wi-Fi Not Supported",
            message: "DHCP cannot be started on a Wi-Fi interface."
        )

        let recovered = try #require(ServiceFailure.from(nsError: original.asNSError))
        #expect(recovered == original)
        #expect(recovered.recoverySuggestion == nil)
        #expect(recovered.technicalDetails == nil)
        #expect(recovered.isRetryable == false)
    }

    @Test("every error code survives the bridge", arguments: ServiceErrorCode.allCases)
    func everyCodeSurvives(code: ServiceErrorCode) throws {
        let original = ServiceFailure(code: code, title: "t", message: "m")
        let recovered = try #require(ServiceFailure.from(nsError: original.asNSError))
        #expect(recovered.code == code)
    }

    @Test("distinct codes produce distinct NSError codes")
    func codesAreDistinct() {
        // A collision would make two different problems indistinguishable to anything that
        // inspects the NSError rather than the payload — Console, crash reports, log search.
        let numericCodes = ServiceErrorCode.allCases.map { ServiceFailure(
            code: $0, title: "t", message: "m"
        ).asNSError.code }

        #expect(Set(numericCodes).count == ServiceErrorCode.allCases.count)
    }

    @Test("populates the localized fields an NSError consumer expects")
    func populatesLocalizedFields() {
        let failure = ServiceFailure(
            code: .dnsmasqHashMismatch,
            title: "Engine Verification Failed",
            message: "The bundled dnsmasq does not match its recorded checksum.",
            recoverySuggestion: "Reinstall MacNetLab."
        )
        let error = failure.asNSError

        #expect(error.localizedDescription == failure.title)
        #expect(error.localizedFailureReason == failure.message)
        #expect(error.localizedRecoverySuggestion == failure.recoverySuggestion)
    }

    @Test("returns nil for an error the helper did not produce")
    func rejectsForeignErrors() {
        // A transport breakage must stay distinguishable from a reported failure: one means
        // the helper is gone, the other means it answered and said no.
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: nil)
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil)

        #expect(ServiceFailure.from(nsError: posix) == nil)
        #expect(ServiceFailure.from(nsError: cocoa) == nil)
    }

    @Test("returns nil when the payload is absent or corrupt")
    func rejectsCorruptPayload() {
        let missing = NSError(domain: ServiceFailure.errorDomain, code: 1, userInfo: [:])
        #expect(ServiceFailure.from(nsError: missing) == nil)

        let corrupt = NSError(
            domain: ServiceFailure.errorDomain,
            code: 1,
            userInfo: ["com.bee.macnetlab.ServiceFailure.payload": Data("not json".utf8)]
        )
        #expect(ServiceFailure.from(nsError: corrupt) == nil)
    }
}
