import Foundation
import Testing
import MacNetModels
@testable import MacNetXPC

/// Size limits are a denial-of-service control on a root process (ticket §7.10), so they are
/// checked before parsing, not after.
@Suite("XPC payload")
struct XPCPayloadTests {

    private struct Blob: Codable, Equatable {
        let value: String
    }

    @Test("round-trips a value")
    func roundTrips() throws {
        let original = Blob(value: "bmc01.lab.test")
        let data = try XPCPayload.encodeRequest(original)
        #expect(try XPCPayload.decodeRequest(Blob.self, from: data) == original)
    }

    @Test("refuses to encode a value larger than the limit")
    func refusesOversizedEncode() throws {
        let oversized = Blob(value: String(repeating: "a", count: XPCLimits.maximumRequestBytes))

        #expect(throws: ServiceFailure.self) {
            try XPCPayload.encodeRequest(oversized)
        }
    }

    @Test("refuses to decode a payload larger than the limit, without parsing it")
    func refusesOversizedDecode() throws {
        // Deliberately not valid JSON: if the limit were checked after parsing, this would
        // fail with a decoding error instead, and the size guard would be doing nothing.
        let oversized = Data(repeating: 0x41, count: XPCLimits.maximumRequestBytes + 1)

        let failure = #expect(throws: ServiceFailure.self) {
            try XPCPayload.decodeRequest(Blob.self, from: oversized)
        }
        #expect(failure?.code == .payloadTooLarge)
    }

    @Test("reports malformed input as an invalid request, not an internal error")
    func reportsMalformedInput() throws {
        let garbage = Data("this is not json".utf8)

        let failure = #expect(throws: ServiceFailure.self) {
            try XPCPayload.decodeRequest(Blob.self, from: garbage)
        }
        // The distinction matters to the user: invalidRequest is their problem to fix,
        // internalError is ours.
        #expect(failure?.code == .invalidRequest)
    }

    @Test("responses may be larger than requests")
    func responseLimitIsLarger() {
        // Requests are small and attacker-influenced; responses carry log and lease
        // snapshots the helper itself produced.
        #expect(XPCLimits.maximumResponseBytes > XPCLimits.maximumRequestBytes)
        #expect(XPCLimits.maximumRequestBytes == 1 * 1024 * 1024)
        #expect(XPCLimits.maximumResponseBytes == 4 * 1024 * 1024)
    }

    @Test("dates cross the wire as ISO-8601")
    func datesUseISO8601() throws {
        struct Timed: Codable { let at: Date }

        let data = try XPCPayload.encodeRequest(Timed(at: Date(timeIntervalSince1970: 0)))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("1970-01-01T00:00:00Z"))
    }
}
