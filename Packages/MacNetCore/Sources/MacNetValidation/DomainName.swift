import Foundation
import MacNetModels

/// Validation and normalization for DNS names.
///
/// Everything the user types that ends up in a dnsmasq configuration file or a hosts file
/// passes through here first. The rules are deliberately narrower than DNS permits: this is
/// the boundary that stops a name from carrying a newline, a comment marker, or a separator
/// that would let it inject a second directive into a generated file.
public enum DomainName {

    /// Longest a fully-qualified name may be.
    public static let maximumLength = 253
    /// Longest a single label may be.
    public static let maximumLabelLength = 63

    /// Default local domain. `.test` is reserved by RFC 2606 for exactly this,
    /// so it can never collide with a real registration.
    public static let defaultLocalDomain = "lab.test"

    public enum Failure: String, Sendable, Equatable, Error {
        case empty
        case tooLong
        case labelEmpty
        case labelTooLong
        case labelHasInvalidCharacter
        case labelStartsWithHyphen
        case labelEndsWithHyphen
        case missingDot
        case reservedForMulticastDNS
    }

    // MARK: - Local domain

    /// Normalizes and validates a local domain such as `lab.test`.
    ///
    /// Normalization is applied before validation, so `  LAB.TEST.  ` is accepted and stored
    /// as `lab.test` rather than rejected on formatting the user cannot see.
    public static func validateLocalDomain(_ input: String) -> Result<String, Failure> {
        let normalized = normalize(input)

        guard !normalized.isEmpty else { return .failure(.empty) }
        guard normalized.count <= maximumLength else { return .failure(.tooLong) }

        // `.local` belongs to multicast DNS. Serving it from a unicast resolver breaks
        // Bonjour discovery on every machine that believes the answer.
        guard normalized != "local", !normalized.hasSuffix(".local") else {
            return .failure(.reservedForMulticastDNS)
        }

        // A single-label local domain would collide with unqualified host lookups.
        guard normalized.contains(".") else { return .failure(.missingDot) }

        if let failure = firstLabelFailure(in: normalized) { return .failure(failure) }
        return .success(normalized)
    }

    /// Lowercases, trims surrounding whitespace, and removes one trailing dot.
    ///
    /// Exactly one trailing dot: `lab.test.` is the same name as `lab.test`, but `lab.test..`
    /// has an empty label and must stay invalid rather than being silently repaired.
    public static func normalize(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        return value
    }

    // MARK: - Labels

    private static func firstLabelFailure(in name: String) -> Failure? {
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            if let failure = labelFailure(label) { return failure }
        }
        return nil
    }

    private static func labelFailure(_ label: Substring) -> Failure? {
        guard !label.isEmpty else { return .labelEmpty }
        guard label.count <= maximumLabelLength else { return .labelTooLong }
        guard label.first != "-" else { return .labelStartsWithHyphen }
        guard label.last != "-" else { return .labelEndsWithHyphen }

        // Allow-list, not a deny-list. A deny-list has to anticipate every dangerous
        // character; this only has to name the safe ones. Underscore is excluded on purpose
        // — it is invalid in a hostname and is a common source of resolver disagreement.
        let isAllowed: (Character) -> Bool = { character in
            character.isASCII && (character.isLowercase && character.isLetter
                || character.isNumber || character == "-")
        }
        guard label.allSatisfy(isAllowed) else { return .labelHasInvalidCharacter }
        return nil
    }
}
