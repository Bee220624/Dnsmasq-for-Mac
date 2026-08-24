import Foundation
import MacNetModels

/// Sorts dnsmasq log lines into the five categories the Logs page filters on (ticket §5.5).
///
/// ## Why word boundaries, not substrings
///
/// The ticket gives keyword lists. Matching them as bare substrings misclassifies real output:
/// `config` is a DNS keyword because dnsmasq writes `config bmc01.lab.test is 192.168.50.20`,
/// but `cannot read config file` would then be filed under DNS rather than Error. `reply`
/// appears inside `replying`; `error` appears inside `errors`. Whole-word matching keeps the
/// ticket's vocabulary while making it mean what it was meant to mean.
///
/// ## Order, and one deliberate departure from the ticket
///
/// Ticket §5.5 lists the categories as DHCP, DNS, Warning, Error, System. Applied as a
/// precedence order that produces a wrong answer for real output:
///
/// ```
/// dnsmasq[421]: cannot read config file
/// ```
///
/// contains `config`, a DNS keyword, and `cannot`, an error keyword. With DNS tried first this
/// is filed under DNS — so an engineer filtering to Errors never learns that their
/// configuration could not be read, which is precisely the moment the Error filter exists for.
///
/// Severity is therefore tried first: **Warning, Error, DHCP, DNS, System**. Warning precedes
/// Error because dnsmasq labels its own non-fatal problems `warning:`, and re-labelling those
/// as errors would cry wolf.
///
/// This costs nothing in practice. dnsmasq's DHCP message types (`DHCPACK`, `DHCPNAK`) never
/// appear inside its failure text, so ordinary lease traffic is unaffected — while
/// `failed to send DHCPOFFER` now correctly reaches someone filtering for failures.
public enum LogClassifier {

    /// The DHCP message types dnsmasq logs (ticket §5.5).
    static let dhcpKeywords: Set<String> = [
        "dhcpdiscover", "dhcpoffer", "dhcprequest",
        "dhcpack", "dhcpnak", "dhcpdecline", "dhcprelease", "dhcpinform",
    ]

    static let dnsKeywords: Set<String> = [
        "forwarded", "reply", "cached", "config", "query",
    ]

    static let warningKeywords: Set<String> = ["warning", "warned"]

    static let errorKeywords: Set<String> = [
        "error", "failed", "cannot", "fatal",
    ]

    /// Multi-word phrases, which word matching alone cannot catch.
    static let errorPhrases: [String] = ["permission denied"]

    public static func category(for line: String) -> LogCategory {
        let lowercased = line.lowercased()

        // dnsmasq writes `query[A] bmc01.lab.test from 192.168.50.20`, so the token carries a
        // bracket and would not match as a bare word.
        if lowercased.contains("query[") { return .dns }

        let words = tokenize(lowercased)

        // Severity first, so nothing that went wrong can be hidden behind a protocol
        // category. See the note above for why this departs from the ticket's listed order.
        if !words.isDisjoint(with: warningKeywords) { return .warning }
        if !words.isDisjoint(with: errorKeywords) { return .error }
        if errorPhrases.contains(where: lowercased.contains) { return .error }

        // `DHCPDISCOVER(en7)` tokenizes to `dhcpdiscover`, which is why the separator set
        // below treats brackets as boundaries.
        if !words.isDisjoint(with: dhcpKeywords) { return .dhcp }
        if !words.isDisjoint(with: dnsKeywords) { return .dns }

        return .system
    }

    /// Splits a line into lowercase words.
    ///
    /// dnsmasq decorates its tokens — `DHCPACK(en7)`, `dnsmasq-dhcp[421]:` — so punctuation is
    /// treated as a boundary rather than part of the word.
    private static func tokenize(_ lowercasedLine: String) -> Set<String> {
        Set(
            lowercasedLine
                .split(whereSeparator: { character in
                    !character.isLetter && !character.isNumber && character != "-"
                })
                .map(String.init)
        )
    }
}
