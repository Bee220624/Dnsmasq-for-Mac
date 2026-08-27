import Foundation
import MacNetModels

/// The result of reading a lease file.
public struct LeaseParseResult: Sendable, Equatable {
    public let leases: [DHCPLease]
    /// Lines that could not be understood.
    ///
    /// Counted and surfaced rather than silently dropped: a lease file with malformed lines is
    /// a sign something is wrong, and a viewer that quietly showed three of five leases would
    /// send an engineer chasing a device that is actually fine.
    public let malformedLines: [MalformedLine]

    public struct MalformedLine: Sendable, Equatable {
        /// 1-based, so it matches what a text editor shows.
        public let lineNumber: Int
        public let reason: String

        public init(lineNumber: Int, reason: String) {
            self.lineNumber = lineNumber
            self.reason = reason
        }
    }

    public init(leases: [DHCPLease], malformedLines: [MalformedLine]) {
        self.leases = leases
        self.malformedLines = malformedLines
    }
}

/// Parses dnsmasq's lease file.
///
/// ## Format
///
/// One lease per line, five space-separated fields:
///
/// ```
/// <expiry> <mac> <ipv4> <hostname> <client-id>
/// 1787558400 00:11:22:33:44:55 192.168.50.10 bmc01 01:00:11:22:33:44:55
/// 0          aa:bb:cc:dd:ee:ff 192.168.50.11 *     *
/// ```
///
/// Expiry `0` means the lease never expires. `*` marks an absent hostname or client ID.
///
/// ## One bad line does not lose the file
///
/// This is the rule that shapes the whole parser. The file is written by another process while
/// we read it, so a torn final line is normal rather than exceptional. Refusing the whole file
/// would empty the leases table at random moments — precisely when an engineer is watching it
/// to find out whether a device got an address.
public struct DnsmasqLeaseParser: Sendable {

    /// Largest lease file that will be read.
    ///
    /// A pool is capped at 1024 addresses and a lease line is well under 100 bytes, so a file
    /// anywhere near this is not a lease file any more. The cap is what stops a runaway file
    /// from making the helper allocate without limit.
    public static let maximumFileBytes = 4 * 1024 * 1024

    public init() {}

    public func parse(_ text: String, now: Date) -> LeaseParseResult {
        var leases: [DHCPLease] = []
        var malformed: [LeaseParseResult.MalformedLine] = []

        for (index, rawLine) in text.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            switch Self.parseLine(line, now: now) {
            case .success(let lease):
                leases.append(lease)
            case .failure(let reason):
                malformed.append(
                    LeaseParseResult.MalformedLine(lineNumber: index + 1, reason: reason)
                )
            }
        }

        // Sorted by numeric address. Sorting here rather than in the view means
        // the order is the same wherever the snapshot is used, and is covered by these tests.
        leases.sort { $0.ipv4Address < $1.ipv4Address }
        return LeaseParseResult(leases: leases, malformedLines: malformed)
    }

    private enum LineOutcome {
        case success(DHCPLease)
        case failure(String)
    }

    private static func parseLine(_ line: String, now: Date) -> LineOutcome {
        // Split on any whitespace run, so extra spaces between fields are tolerated.
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)

        // At least five. dnsmasq may append more for some client types, and extra trailing
        // fields are ignored rather than treated as an error — a stricter check would reject
        // leases that are perfectly readable.
        guard fields.count >= 5 else {
            return .failure("expected at least 5 fields, found \(fields.count)")
        }

        guard let expirySeconds = UInt64(fields[0]) else {
            return .failure("expiry '\(fields[0])' is not a number")
        }

        guard let macAddress = normalizedMAC(fields[1]) else {
            return .failure("'\(fields[1])' is not a hardware address")
        }

        guard let address = IPv4Address(fields[2]) else {
            return .failure("'\(fields[2])' is not an IPv4 address")
        }

        let hostname = fields[3] == "*" ? nil : fields[3]
        let clientID = fields[4] == "*" ? nil : fields[4]

        // Expiry 0 is dnsmasq's marker for a lease that never expires.
        if expirySeconds == 0 {
            return .success(DHCPLease(
                expiresAt: nil, macAddress: macAddress, ipv4Address: address,
                hostname: hostname, clientID: clientID, status: .infinite
            ))
        }

        let expiresAt = Date(timeIntervalSince1970: TimeInterval(expirySeconds))
        return .success(DHCPLease(
            expiresAt: expiresAt,
            macAddress: macAddress,
            ipv4Address: address,
            hostname: hostname,
            clientID: clientID,
            status: expiresAt > now ? .active : .expired
        ))
    }

    /// Validates and lowercases a hardware address.
    ///
    /// Normalized so that the same device is one row however dnsmasq happened to write it —
    /// the lease id is built from this, and a case difference would split one device into two.
    static func normalizedMAC(_ value: String) -> String? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)

        // Six octets is Ethernet. dnsmasq can write other lengths for unusual media, which
        // v0.1 does not claim to support, so they are reported rather than half-understood.
        guard parts.count == 6 else { return nil }

        var octets: [String] = []
        for part in parts {
            guard part.count == 2 || part.count == 1,
                  UInt8(part, radix: 16) != nil
            else { return nil }
            // Pad a single-digit octet so the rendered form is uniform.
            octets.append(part.count == 1 ? "0\(part.lowercased())" : part.lowercased())
        }
        return octets.joined(separator: ":")
    }
}
