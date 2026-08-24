import Testing
import MacNetValidation

@Suite("Hostname validation")
struct HostnameTests {

    private let domain = "lab.test"

    private func resolved(_ input: String) throws -> Hostname.Resolved {
        try Hostname.resolve(input, localDomain: domain).get()
    }

    private func rejection(_ input: String) -> Hostname.Failure? {
        if case .failure(let failure) = Hostname.resolve(input, localDomain: domain) {
            return failure
        }
        return nil
    }

    @Test("qualifies a relative name against the local domain")
    func qualifiesRelativeName() throws {
        let result = try resolved("bmc01")

        #expect(result.fullyQualified == "bmc01.lab.test")
        // Both names are written so that either form resolves for a client.
        #expect(result.shortName == "bmc01")
        #expect(result.hostsFileNames == ["bmc01.lab.test", "bmc01"])
    }

    @Test("leaves a fully-qualified name alone")
    func leavesFQDNAlone() throws {
        let result = try resolved("bmc01.lab.test")

        // Appending the domain again would produce bmc01.lab.test.lab.test (ticket §7.7).
        #expect(result.fullyQualified == "bmc01.lab.test")
        #expect(result.shortName == nil)
        #expect(result.hostsFileNames == ["bmc01.lab.test"])
    }

    @Test("qualifies against a domain the record does not share")
    func qualifiesAcrossDomains() throws {
        // A name that is already qualified is taken as-is even when it sits under a different
        // domain — the user asked for that name specifically.
        let result = try resolved("switch01.other.test")
        #expect(result.fullyQualified == "switch01.other.test")
        #expect(result.shortName == nil)
    }

    @Test("accepts the shapes real device names take",
          arguments: ["bmc01", "server-01", "bmc01.lab.test", "a", "host1", "r1-u42-bmc"])
    func acceptsRealisticNames(input: String) throws {
        #expect(try resolved(input).fullyQualified.hasPrefix(input.lowercased()))
    }

    @Test("normalizes case and surrounding whitespace")
    func normalizes() throws {
        #expect(try resolved("BMC01").fullyQualified == "bmc01.lab.test")
        #expect(try resolved("  bmc01  ").fullyQualified == "bmc01.lab.test")
    }

    @Test("rejects empty input")
    func rejectsEmpty() {
        #expect(rejection("") == .empty)
        #expect(rejection("   ") == .empty)
    }

    @Test("rejects internal whitespace with a specific reason",
          arguments: ["bmc 01", "bmc\t01", "bmc\n01", "bmc\r01"])
    func rejectsInternalWhitespace(input: String) {
        // Named specifically rather than lumped in with "invalid character": a space is the
        // most likely thing a user types by accident, and deserves an explanation that says so.
        #expect(rejection(input) == .containsWhitespace)
    }

    @Test("rejects hyphens at the edge of a label")
    func rejectsEdgeHyphens() {
        #expect(rejection("-bmc01") == .labelStartsWithHyphen)
        #expect(rejection("bmc01-") == .labelEndsWithHyphen)
    }

    @Test("enforces label and total length limits")
    func enforcesLengthLimits() {
        #expect(rejection(String(repeating: "a", count: 64)) == .labelTooLong)
        #expect(rejection(String(repeating: "a", count: 63)) == nil)

        let longFQDN = Array(repeating: String(repeating: "a", count: 63), count: 4)
            .joined(separator: ".")
        #expect(rejection(longFQDN) == .tooLong)
    }

    /// A host name is written into a generated hosts file, one record per line. Anything that
    /// can end a line, start a comment, or separate a field would let a name become an extra
    /// entry — or an extra dnsmasq directive.
    @Test("rejects characters that would inject into a generated hosts file",
          arguments: ["bmc01\nserver=1.2.3.4",
                      "bmc01#comment",
                      "bmc01,server=evil",
                      "bmc01;rm -rf /",
                      "bmc01/../etc/passwd",
                      "bmc01\\evil",
                      "bmc01$(whoami)",
                      "bmc01`whoami`",
                      "bmc01|cat",
                      "bmc01&background",
                      "bmc01>out",
                      "bmc01<in",
                      "bmc01'quote",
                      "bmc01\"quote",
                      "bmc01*glob",
                      "bmc01?glob",
                      "bmc01 192.168.1.1 evil.host",
                      "192.168.50.1 evil"])
    func rejectsHostsFileInjection(input: String) {
        #expect(rejection(input) != nil, "must reject: \(input.debugDescription)")
    }
}
