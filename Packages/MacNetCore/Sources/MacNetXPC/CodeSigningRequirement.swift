import Foundation

/// Builds the code signing requirement strings used to pin both ends of the XPC channel.
///
/// ## Why this exists in the shared core
///
/// Both sides pin the other: the helper constrains its listener to the app, and the app
/// constrains its connection to the helper. Writing that string twice invites the two copies
/// to drift, and a requirement that is subtly wrong in one direction is a security hole that
/// nothing else in the system will catch. One implementation, tested once, is used by both.
///
/// ## What the requirement asserts
///
/// * `identifier "<bundle id>"` — the peer is that exact program, not merely something else
///   from the same team.
/// * `anchor apple generic` — the signature chains to an Apple-issued certificate, so an
///   ad-hoc or self-signed binary claiming the same identifier fails.
/// * `certificate leaf[subject.OU] = "<team id>"` — the leaf certificate belongs to our team.
///
/// The three together hold for Apple Development *and* Developer ID signing, because the Team
/// ID appears in the leaf certificate's OU in both. That is what lets development builds run
/// under exactly the same verification as release builds, with no relaxed branch anywhere
///.
public enum CodeSigningRequirement {

    /// Builds a requirement pinning a program by identifier and signing team.
    ///
    /// Returns `nil` if either input is missing or contains anything that is not a plain
    /// identifier character. Callers must treat `nil` as fatal: a root service that cannot
    /// build a requirement must refuse to serve, never fall back to accepting all callers.
    public static func forSignedProgram(
        bundleIdentifier: String?,
        teamIdentifier: String?
    ) -> String? {
        guard let bundleIdentifier = sanitized(bundleIdentifier),
              let teamIdentifier = sanitized(teamIdentifier)
        else { return nil }

        return #"identifier "\#(bundleIdentifier)" and anchor apple generic "#
            + #"and certificate leaf[subject.OU] = "\#(teamIdentifier)""#
    }

    /// Rejects anything that could change the meaning of the requirement it is spliced into.
    ///
    /// A requirement is a small language with its own operators, quoting, and comments. These
    /// values come from our own embedded Info.plist rather than from a caller, so in practice
    /// this never fires — but interpolating unchecked into a requirement is the same class of
    /// mistake as building a shell command by concatenation, which this project forbids
    /// everywhere else. Allowing only identifier characters makes the whole class impossible.
    static func sanitized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }

        let isAllowed: (Character) -> Bool = { character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "." || character == "-")
        }
        guard value.allSatisfy(isAllowed) else { return nil }
        return value
    }
}
