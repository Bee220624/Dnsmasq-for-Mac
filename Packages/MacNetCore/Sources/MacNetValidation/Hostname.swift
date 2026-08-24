import Foundation
import MacNetModels

/// Validation for host names entered as local DNS records (ticket §7.7).
public enum Hostname {

    public enum Failure: String, Sendable, Equatable, Error {
        case empty
        case tooLong
        case containsWhitespace
        case containsForbiddenCharacter
        case labelEmpty
        case labelTooLong
        case labelStartsWithHyphen
        case labelEndsWithHyphen
    }

    /// A validated host name, together with how it should be written into a hosts file.
    public struct Resolved: Sendable, Equatable {
        /// The fully-qualified name.
        public let fullyQualified: String
        /// The bare first label, present only when the user gave a relative name.
        ///
        /// `bmc01` is written as both `bmc01.lab.test` and `bmc01` so either resolves. A name
        /// the user already qualified is written once, exactly as given — appending the local
        /// domain to `bmc01.lab.test` would produce `bmc01.lab.test.lab.test` (ticket §7.7).
        public let shortName: String?

        /// Names to emit for this record, in the order dnsmasq expects: FQDN first.
        public var hostsFileNames: [String] {
            if let shortName { return [fullyQualified, shortName] }
            return [fullyQualified]
        }
    }

    /// Validates a host name and qualifies it against `localDomain` if it is relative.
    ///
    /// `localDomain` must already have passed `DomainName.validateLocalDomain`.
    public static func resolve(
        _ input: String,
        localDomain: String
    ) -> Result<Resolved, Failure> {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !normalized.isEmpty else { return .failure(.empty) }

        // Checked explicitly, before anything else, so the failure names the real problem
        // instead of surfacing as a confusing "invalid character".
        if normalized.contains(where: { $0.isWhitespace || $0.isNewline }) {
            return .failure(.containsWhitespace)
        }

        // These are the characters that would let a name escape its field and become
        // configuration: a comment marker, a path separator, an escape, or a value separator
        // in dnsmasq's own syntax.
        let forbidden: Set<Character> = ["#", "/", "\\", ",", ";", "=", "'", "\"", "`",
                                         "$", "|", "&", "<", ">", "(", ")", "*", "?", "!",
                                         "[", "]", "{", "}", "~", "^", "%", "+", ":", "@"]
        if normalized.contains(where: forbidden.contains) {
            return .failure(.containsForbiddenCharacter)
        }

        let isRelative = !normalized.contains(".")
        let fullyQualified = isRelative ? "\(normalized).\(localDomain)" : normalized

        guard fullyQualified.count <= DomainName.maximumLength else { return .failure(.tooLong) }
        if let failure = firstLabelFailure(in: fullyQualified) { return .failure(failure) }

        return .success(Resolved(
            fullyQualified: fullyQualified,
            shortName: isRelative ? normalized : nil
        ))
    }

    private static func firstLabelFailure(in name: String) -> Failure? {
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty else { return .labelEmpty }
            guard label.count <= DomainName.maximumLabelLength else { return .labelTooLong }
            guard label.first != "-" else { return .labelStartsWithHyphen }
            guard label.last != "-" else { return .labelEndsWithHyphen }

            let isAllowed: (Character) -> Bool = { character in
                character.isASCII && (character.isLowercase && character.isLetter
                    || character.isNumber || character == "-")
            }
            guard label.allSatisfy(isAllowed) else { return .containsForbiddenCharacter }
        }
        return nil
    }
}
