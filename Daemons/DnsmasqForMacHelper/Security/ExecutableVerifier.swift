import Darwin
import Foundation
import MacNetModels
import OSLog
import Security

/// Verifies the bundled dnsmasq before the helper executes it as root (ticket §21.3).
///
/// ## What is checked, and why it is not a digest comparison
///
/// The ticket asks for a SHA-256 recomputed at launch against a compile-time constant. That is
/// not constructible: `codesign` writes the signature *into* the Mach-O, so the bytes in the
/// bundle differ from the compiler's output, and the helper is compiled before dnsmasq is
/// signed. No constant compiled into this binary can describe the signed file, and the signing
/// identity differs between Debug and Release besides. Implemented literally, the check would
/// fail on every launch. `Docs/RISKS.md` R-13 records the deviation.
///
/// What is checked instead answers the same question — *is this the dnsmasq we shipped?* —
/// more strongly:
///
/// 1. **Code signature** against a requirement pinned to our Team ID. This is the same
///    mechanism that authenticates the XPC peer, and unlike a digest it proves provenance
///    rather than matching a number that an attacker able to replace the binary could also
///    replace.
/// 2. **File properties**: a regular file, not a symlink, not writable by group or others, and
///    owned by root. A binary a normal user can rewrite is a binary this root process would
///    happily execute.
/// 3. **Version and compiled features**, from `--version`.
struct ExecutableVerifier: ExecutableVerifying {

    let commandRunner: any CommandRunning
    let fileManager: RuntimeFileManager

    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "verify")

    init(commandRunner: any CommandRunning, fileManager: RuntimeFileManager) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    func verifyBundledDnsmasq() async throws(ServiceFailure) -> ExecutableVerification {
        let path = BundledPaths.dnsmasq

        try Self.verifyFileProperties(at: path)
        try Self.verifyCodeSignature(at: path, teamIdentifier: HelperIdentity.teamIdentifier)

        let digest = try fileManager.digest(ofFileAt: path)
        let (version, architectures, compileOptions) = try await readVersion(at: path)

        logger.log(
            """
            verified dnsmasq: version=\(version, privacy: .public) \
            archs=\(architectures, privacy: .public)
            """
        )

        return ExecutableVerification(
            path: path, sha256: digest, version: version,
            architectures: architectures, compileOptions: compileOptions
        )
    }

    // MARK: - File properties

    private static func verifyFileProperties(at path: String) throws(ServiceFailure) {
        // lstat, not stat: stat follows symlinks, which would report on the target and miss
        // exactly the substitution this check exists to catch.
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw ServiceFailure(
                code: .dnsmasqMissing,
                title: "Engine Not Found",
                message: "The bundled DNS and DHCP engine is missing.",
                recoverySuggestion: "Reinstall Dnsmasq for Mac from your original download.",
                technicalDetails: "\(path): \(String(cString: strerror(errno)))",
                isRetryable: false
            )
        }

        guard status.st_mode & S_IFMT == S_IFREG else {
            throw Self.rejected(
                path, "is not a regular file",
                "a symlink or special file could point anywhere"
            )
        }
        guard status.st_uid == 0 else {
            throw Self.rejected(
                path, "is not owned by root",
                "owner uid \(status.st_uid); a non-root owner could replace it"
            )
        }
        guard status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw Self.rejected(
                path, "is writable by other users",
                "mode \(String(status.st_mode & 0o777, radix: 8))"
            )
        }
    }

    private static func rejected(
        _ path: String, _ summary: String, _ detail: String
    ) -> ServiceFailure {
        ServiceFailure(
            code: .dnsmasqHashMismatch,
            title: "Engine Verification Failed",
            message: "The bundled DNS and DHCP engine \(summary), so Dnsmasq for Mac will not run it.",
            recoverySuggestion: "Reinstall Dnsmasq for Mac from your original download.",
            technicalDetails: "\(path): \(detail)",
            isRetryable: false
        )
    }

    // MARK: - Code signature

    private static func verifyCodeSignature(
        at path: String,
        teamIdentifier: String?
    ) throws(ServiceFailure) {
        guard let teamIdentifier, !teamIdentifier.isEmpty else {
            throw ServiceFailure.internalError(
                "the helper has no team identifier; its Info.plist is incomplete"
            )
        }

        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            throw rejected(path, "has no readable code signature", "SecStaticCodeCreateWithPath failed")
        }

        // Deliberately not pinning `identifier`: dnsmasq is signed ad-hoc-of-identity by our
        // build, and its signing identifier is derived from the file name rather than chosen.
        // Anchor plus team is what actually matters — it says this binary was signed by us
        // with an Apple-issued certificate.
        let requirementText = #"anchor apple generic and certificate leaf[subject.OU] = "\#(teamIdentifier)""#

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString, [], &requirement
        ) == errSecSuccess, let requirement else {
            throw ServiceFailure.internalError("could not compile the dnsmasq code requirement")
        }

        let status = SecStaticCodeCheckValidity(staticCode, [.enforceRevocationChecks], requirement)
        guard status == errSecSuccess else {
            throw rejected(
                path, "is not signed by this developer",
                "SecStaticCodeCheckValidity returned \(status) against \(requirementText)"
            )
        }
    }

    // MARK: - Version

    private func readVersion(
        at path: String
    ) async throws(ServiceFailure) -> (String, String, String) {
        let result: CommandResult
        do {
            result = try await commandRunner.run(
                .bundledDnsmasq, arguments: ["--version"],
                currentDirectory: nil, timeout: .seconds(10)
            )
        } catch let failure as ServiceFailure {
            throw failure
        } catch {
            throw ServiceFailure.internalError("could not run dnsmasq --version: \(error)")
        }

        let output = result.standardOutput + result.standardError
        let expected = DnsmasqBinaryIdentity.version

        guard output.contains("Dnsmasq version \(expected)") else {
            throw Self.rejected(
                path, "is not the expected version",
                "expected \(expected); --version said: "
                    + output.split(separator: "\n").first.map(String.init).orEmpty
            )
        }

        // Features that were compiled out must stay out. Asserted on the shipped binary
        // because this is the one that will actually run (ticket §3.5).
        let options = " \(output.replacingOccurrences(of: "\n", with: " ")) "
        guard options.contains(" DHCP ") else {
            throw Self.rejected(path, "has no DHCP support", "DHCP is not in the compile options")
        }
        for forbidden in ["TFTP", "DHCPv6", "auth", "dumpfile", "scripts"] {
            guard !options.contains(" \(forbidden) ") else {
                throw Self.rejected(
                    path, "was built with \(forbidden) enabled",
                    "compile options include \(forbidden), which v0.1 forbids"
                )
            }
        }

        let compileOptions = output
            .split(separator: "\n")
            .first { $0.hasPrefix("Compile time options:") }
            .map { $0.replacingOccurrences(of: "Compile time options: ", with: "") }
            ?? ""

        return (expected, Self.machOArchitectures(at: path), String(compileOptions))
    }

    /// Reads the architecture list straight from the Mach-O header.
    ///
    /// Done in-process rather than by shelling out to `lipo`: the helper's executable set is
    /// closed by design (ticket §21.2), and adding a tool to it for a cosmetic field would be
    /// a poor trade.
    private static func machOArchitectures(at path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path),
              let header = try? handle.read(upToCount: 4096)
        else { return "unknown" }
        defer { try? handle.close() }

        func value(at offset: Int) -> UInt32? {
            guard header.count >= offset + 4 else { return nil }
            return header.subdata(in: offset..<(offset + 4))
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        }

        // A fat binary starts with FAT_CIGAM/FAT_MAGIC and a big-endian architecture count.
        guard let magic = value(at: 0),
              magic == 0xCAFE_BABE || magic == 0xBEBA_FECA,
              let count = value(at: 4), count > 0, count < 32
        else {
            return "single-architecture"
        }

        var names: [String] = []
        for index in 0..<Int(count) {
            // Each fat_arch is 20 bytes, cputype first.
            guard let cpuType = value(at: 8 + index * 20) else { continue }
            switch Int32(bitPattern: cpuType) {
            case 0x0100_000C: names.append("arm64")
            case 0x0100_0007: names.append("x86_64")
            default: names.append("cpu:\(cpuType)")
            }
        }
        return names.isEmpty ? "unknown" : names.joined(separator: " ")
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
