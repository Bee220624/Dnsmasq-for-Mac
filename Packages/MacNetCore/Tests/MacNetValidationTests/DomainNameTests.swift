import Testing
import MacNetValidation

@Suite("Local domain validation")
struct DomainNameTests {

    private func accepted(_ input: String) throws -> String {
        try DomainName.validateLocalDomain(input).get()
    }

    private func rejection(_ input: String) -> DomainName.Failure? {
        if case .failure(let failure) = DomainName.validateLocalDomain(input) { return failure }
        return nil
    }

    @Test("accepts the default and other ordinary domains",
          arguments: ["lab.test", "example.test", "rack1.lab.test", "a.b", "test-1.lab.test",
                      "lab2.test"])
    func acceptsOrdinaryDomains(input: String) throws {
        #expect(try accepted(input) == input)
    }

    @Test("normalizes case, surrounding whitespace, and one trailing dot",
          arguments: [("LAB.TEST", "lab.test"),
                      ("Lab.Test", "lab.test"),
                      ("  lab.test  ", "lab.test"),
                      ("lab.test.", "lab.test"),
                      ("\tLAB.TEST.\n", "lab.test")])
    func normalizes(input: String, expected: String) throws {
        // Normalizing before validating means the user is not told off for formatting they
        // cannot see, while what gets stored and written to dnsmasq is canonical.
        #expect(try accepted(input) == expected)
    }

    @Test("rejects a second trailing dot rather than repairing it")
    func rejectsDoubleTrailingDot() {
        // One trailing dot is the same name; two leaves an empty label, which is a different
        // input and should not be silently fixed.
        #expect(rejection("lab.test..") == .labelEmpty)
    }

    @Test("rejects .local, which belongs to Bonjour",
          arguments: ["lab.local", "local", "LAB.LOCAL", "a.b.local", "lab.local."])
    func rejectsMulticastDNSDomain(input: String) {
        // Answering .local from a unicast resolver breaks service discovery on every machine
        // that believes the answer.
        #expect(rejection(input) == .reservedForMulticastDNS)
    }

    @Test("requires more than one label")
    func requiresDot() {
        #expect(rejection("test") == .missingDot)
        #expect(rejection("lab") == .missingDot)
    }

    @Test("rejects underscores, which are invalid in host names")
    func rejectsUnderscore() {
        #expect(rejection("lab_1.test") == .labelHasInvalidCharacter)
        #expect(rejection("_lab.test") == .labelHasInvalidCharacter)
    }

    @Test("rejects hyphens at the edge of a label")
    func rejectsEdgeHyphens() {
        #expect(rejection("-lab.test") == .labelStartsWithHyphen)
        #expect(rejection("lab-.test") == .labelEndsWithHyphen)
        #expect(rejection("lab.-test") == .labelStartsWithHyphen)
        #expect(rejection("lab.test-") == .labelEndsWithHyphen)
    }

    @Test("enforces the label and name length limits")
    func enforcesLengthLimits() throws {
        let longLabel = String(repeating: "a", count: 64)
        #expect(rejection("\(longLabel).test") == .labelTooLong)

        let maximumLabel = String(repeating: "a", count: 63)
        #expect(try accepted("\(maximumLabel).test") == "\(maximumLabel).test")

        // Four 63-character labels plus separators exceeds 253.
        let tooLong = Array(repeating: maximumLabel, count: 4).joined(separator: ".")
        #expect(rejection(tooLong) == .tooLong)
    }

    @Test("rejects empty input")
    func rejectsEmpty() {
        #expect(rejection("") == .empty)
        #expect(rejection("   ") == .empty)
        #expect(rejection(".") == .empty)
    }

    /// Each of these would change the meaning of the generated dnsmasq configuration if it
    /// reached the file: a newline starts a new directive, `#` comments the rest of the line
    /// out, and a comma separates values within a directive.
    @Test("rejects characters that would inject into a generated config",
          arguments: ["lab.test\nserver=1.2.3.4",
                      "lab.test#comment",
                      "lab.test,server=evil.example",
                      "lab.test;drop",
                      "lab.test server=1.2.3.4",
                      "lab.test/../etc",
                      "lab.test\\x",
                      "lab.test\r\nlisten-address=0.0.0.0",
                      "lab.test\u{0}null"])
    func rejectsConfigInjection(input: String) {
        #expect(rejection(input) != nil, "must reject: \(input.debugDescription)")
    }
}
