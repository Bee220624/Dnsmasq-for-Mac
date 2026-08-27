import Testing
@testable import MacNetXPC

/// The requirement string is the entire caller-verification decision. If it is malformed,
/// too permissive, or influenced by its inputs, the root helper's security boundary is gone.
@Suite("Code signing requirement")
struct CodeSigningRequirementTests {

    @Test("produces the exact expected requirement")
    func producesExpectedRequirement() throws {
        let requirement = CodeSigningRequirement.forSignedProgram(
            bundleIdentifier: "com.bee.dnsmasqformac",
            teamIdentifier: "MDUMXF88CA"
        )

        // Pinned verbatim rather than checked for substrings: this exact string was validated
        // with `csreq` and against the real signed bundle, so any change to it must be a
        // deliberate edit to this expectation, not a silent drift.
        let expected = "identifier \"com.bee.dnsmasqformac\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"MDUMXF88CA\""

        #expect(requirement == expected)
    }

    @Test("asserts all three conditions")
    func assertsAllThreeConditions() throws {
        let requirement = try #require(CodeSigningRequirement.forSignedProgram(
            bundleIdentifier: "com.bee.dnsmasqformac",
            teamIdentifier: "MDUMXF88CA"
        ))

        // Identity alone is not enough: without the anchor, an ad-hoc signature claiming the
        // same identifier would pass. Without the team, any Apple-signed app would.
        #expect(requirement.contains(#"identifier "com.bee.dnsmasqformac""#))
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains(#"certificate leaf[subject.OU] = "MDUMXF88CA""#))
    }

    @Test("rejects missing inputs rather than emitting a partial requirement",
          arguments: [
            (String?.none, String?.some("MDUMXF88CA")),
            (String?.some("com.bee.dnsmasqformac"), String?.none),
            (String?.some(""), String?.some("MDUMXF88CA")),
            (String?.some("com.bee.dnsmasqformac"), String?.some("")),
            (String?.none, String?.none),
          ])
    func rejectsMissingInputs(bundleIdentifier: String?, teamIdentifier: String?) {
        // Returning nil forces the caller to fail closed. A "best effort" requirement built
        // from half the inputs would be worse than none at all.
        #expect(CodeSigningRequirement.forSignedProgram(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier
        ) == nil)
    }

    /// Requirement strings are a language. These inputs would each change the meaning of the
    /// requirement they are spliced into — quoting out of the identifier, appending an `or`
    /// clause that matches anything, or commenting the rest away.
    @Test("rejects inputs that could alter the requirement's meaning",
          arguments: [
            #"com.bee.dnsmasqformac" or anchor apple"#,
            "com.bee.dnsmasqformac\" /* ",
            "com.bee.dnsmasqformac and anchor apple",
            "com.bee.dnsmasqformac\nidentifier \"x\"",
            "com.bee.dnsmasqformac\\",
            "com.bee.dnsmasqformac;",
            "com.bee.dnsmasqformac ",
            " com.bee.dnsmasqformac",
            "com.bee.dnsmasqformac\"",
            "com.bee.dnsmasqformac[1]",
            "com.bee.dnsmasqformac$(whoami)",
          ])
    func rejectsInjectionAttempts(malicious: String) {
        #expect(CodeSigningRequirement.forSignedProgram(
            bundleIdentifier: malicious,
            teamIdentifier: "MDUMXF88CA"
        ) == nil)

        #expect(CodeSigningRequirement.forSignedProgram(
            bundleIdentifier: "com.bee.dnsmasqformac",
            teamIdentifier: malicious
        ) == nil)
    }

    @Test("accepts the identifier characters real bundle ids and team ids use",
          arguments: ["com.bee.dnsmasqformac", "com.bee.dnsmasqformac.helper", "MDUMXF88CA", "A1B2C3D4E5",
                      "com.example.my-app", "com.example.app2"])
    func acceptsLegitimateIdentifiers(identifier: String) {
        #expect(CodeSigningRequirement.sanitized(identifier) == identifier)
    }
}
