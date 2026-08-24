import Darwin
import Foundation
import MacNetDnsmasq
import MacNetModels
import OSLog
import CryptoKit

/// Owns everything under `/var/db/com.bee.macnetlab` (ticket §11).
///
/// ## Why the app never names a path
///
/// Every path here is derived from a fixed root plus a `UUID` this process generated. Ticket
/// §21.4 requires session directories to be named from a UUID rather than from a profile name,
/// hostname, or interface name — none of which are ours, and any of which could contain a
/// separator or `..`. Taking a `UUID` rather than a `String` makes traversal unrepresentable
/// instead of merely rejected.
///
/// Ownership is equally deliberate. dnsmasq drops to `nobody` once its sockets are open, so it
/// must be able to *write* the lease, log, and pid files — but not create new ones. Those three
/// are pre-created as `nobody:nobody 0640` inside a directory that stays `root:nobody 0750`,
/// which gives the dropped-privilege process exactly the access it needs and nothing more.
struct RuntimeFileManager: RuntimeFileManaging {

    /// Fixed root. Never supplied by a caller.
    static let runtimeRoot = "/var/db/com.bee.macnetlab"

    private let root: String
    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "runtime-files")

    /// `FileManager.default` is used directly rather than stored.
    ///
    /// `FileManager` is not `Sendable`, and this type must be — it is reached from the session
    /// coordinator actor. Apple documents the shared instance as safe to use concurrently for
    /// the path-based operations here, so holding an injected instance would buy nothing and
    /// cost the conformance. Tests point `root` at a temporary directory instead, which is the
    /// substitution that actually matters.
    private var fileManager: FileManager { .default }

    private let ownershipApplier: any OwnershipApplying

    init(
        root: String = RuntimeFileManager.runtimeRoot,
        ownershipApplier: any OwnershipApplying = PosixOwnershipApplier()
    ) {
        self.root = root
        self.ownershipApplier = ownershipApplier
    }

    var sessionsDirectory: String { "\(root)/sessions" }
    var journalPath: String { "\(root)/active-session.json" }
    var lockPath: String { "\(root)/lock" }

    // MARK: - Layout

    func prepareRuntimeRoot() throws(ServiceFailure) {
        try createDirectory(at: root, ownership: .privateToRootDirectory)
        try createDirectory(at: sessionsDirectory, ownership: .privateToRootDirectory)
    }

    func createSessionDirectory(sessionID: UUID) throws(ServiceFailure) -> any RuntimePathsProviding {
        let paths = RuntimePaths(runtimeRoot: root, sessionID: sessionID)

        // Belt and braces: the path is built from a UUID, so it cannot escape — but asserting
        // it lands inside the sessions directory means a future refactor that changes how
        // paths are built fails here rather than silently writing somewhere else.
        try assertWithinSessionsDirectory(paths.sessionDirectory)

        try createDirectory(at: paths.sessionDirectory, ownership: .sessionDirectory)
        return paths
    }

    func removeSessionDirectory(sessionID: UUID) throws(ServiceFailure) {
        let paths = RuntimePaths(runtimeRoot: root, sessionID: sessionID)
        try assertWithinSessionsDirectory(paths.sessionDirectory)

        guard fileManager.fileExists(atPath: paths.sessionDirectory) else { return }
        do {
            try fileManager.removeItem(atPath: paths.sessionDirectory)
        } catch {
            throw ServiceFailure(
                code: .cleanupFailed,
                title: "Could Not Remove Session Files",
                message: "The temporary files for this session could not be deleted.",
                technicalDetails: "\(paths.sessionDirectory): \(error)",
                isRetryable: true
            )
        }
    }

    /// Confirms a path really is inside the sessions directory after normalization.
    private func assertWithinSessionsDirectory(_ path: String) throws(ServiceFailure) {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        let base = URL(fileURLWithPath: sessionsDirectory).standardizedFileURL.path

        guard resolved.hasPrefix(base + "/") else {
            throw ServiceFailure.internalError(
                "refusing to operate on \(resolved), which is outside \(base)"
            )
        }
    }

    // MARK: - Files

    func write(
        _ contents: String,
        to path: String,
        ownership: FileOwnership
    ) throws(ServiceFailure) {
        let data = Data(contents.utf8)

        // Written to a temporary name in the same directory and renamed, so a reader — or a
        // crash — never sees a half-written configuration.
        let temporary = "\(path).tmp-\(UUID().uuidString)"

        do {
            try data.write(to: URL(fileURLWithPath: temporary), options: [.atomic])

            // Ticket §15.1 step 7: fsync before the rename. A rename is durable long before
            // the bytes are, and dnsmasq reading a zero-length config after a power loss would
            // be a genuinely confusing failure.
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: temporary))
            try handle.synchronize()
            try handle.close()

            try applyOwnership(ownership, to: temporary)
            // POSIX rename replaces atomically; FileManager.moveItem refuses an existing
            // destination, so the C call is the correct tool here.
            guard rename(temporary, path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(atPath: temporary)
            throw ServiceFailure(
                code: .internalError,
                title: "Could Not Write Runtime File",
                message: "A file needed to run the service could not be written.",
                technicalDetails: "\(path): \(error)",
                isRetryable: true
            )
        }
    }

    func createEmptyFile(at path: String, ownership: FileOwnership) throws(ServiceFailure) {
        // Truncated rather than left alone: a stale lease file from a previous session would
        // otherwise be presented as this session's leases.
        guard fileManager.createFile(atPath: path, contents: Data()) else {
            throw ServiceFailure(
                code: .internalError,
                title: "Could Not Create Runtime File",
                message: "A file needed to run the service could not be created.",
                technicalDetails: path,
                isRetryable: true
            )
        }
        try applyOwnership(ownership, to: path)
    }

    func readFile(at path: String, maximumBytes: Int) throws(ServiceFailure) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ServiceFailure(
                code: .internalError,
                title: "Could Not Read Runtime File",
                message: "A file needed by the service could not be read.",
                technicalDetails: path,
                isRetryable: true
            )
        }
        defer { try? handle.close() }

        // Bounded read. A lease or log file that has grown unexpectedly must not be able to
        // make the root helper allocate without limit (ticket §18.3).
        let data = (try? handle.read(upToCount: maximumBytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func digest(ofFileAt path: String) throws(ServiceFailure) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ServiceFailure(
                code: .dnsmasqMissing,
                title: "Could Not Read Program",
                message: "A required program could not be read for verification.",
                technicalDetails: path,
                isRetryable: false
            )
        }
        defer { try? handle.close() }

        // Streamed in chunks so digesting a Universal binary never loads it whole.
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Ownership

    private func createDirectory(
        at path: String,
        ownership: FileOwnership
    ) throws(ServiceFailure) {
        if !fileManager.fileExists(atPath: path) {
            do {
                try fileManager.createDirectory(
                    atPath: path, withIntermediateDirectories: true, attributes: nil
                )
            } catch {
                throw ServiceFailure(
                    code: .internalError,
                    title: "Could Not Create Runtime Directory",
                    message: "MacNetLab could not create its working directory.",
                    technicalDetails: "\(path): \(error)",
                    isRetryable: true
                )
            }
        }
        try applyOwnership(ownership, to: path)
    }

    private func applyOwnership(
        _ ownership: FileOwnership,
        to path: String
    ) throws(ServiceFailure) {
        try ownershipApplier.apply(ownership, to: path)
    }
}

/// The real thing: `chown` and `chmod`.
struct PosixOwnershipApplier: OwnershipApplying {

    func apply(_ ownership: FileOwnership, to path: String) throws(ServiceFailure) {
        // Names are resolved at the time of use rather than hardcoded, because `nobody` is
        // uid/gid -2 on macOS — an unusual value that is easy to get wrong, and one that would
        // silently create files the dropped-privilege dnsmasq cannot write.
        guard let uid = Self.userID(named: ownership.owner) else {
            throw ServiceFailure.internalError("no such user: \(ownership.owner)")
        }
        guard let gid = Self.groupID(named: ownership.group) else {
            throw ServiceFailure.internalError("no such group: \(ownership.group)")
        }

        // chown before chmod: chown clears the setuid and setgid bits, so doing it second
        // would undo the mode that was just set.
        guard chown(path, uid, gid) == 0 else {
            throw ServiceFailure.internalError(
                "chown \(ownership.owner):\(ownership.group) \(path) failed: "
                    + String(cString: strerror(errno))
            )
        }
        guard chmod(path, mode_t(ownership.permissions)) == 0 else {
            throw ServiceFailure.internalError(
                "chmod \(String(ownership.permissions, radix: 8)) \(path) failed: "
                    + String(cString: strerror(errno))
            )
        }
    }

    static func userID(named name: String) -> uid_t? {
        guard let entry = getpwnam(name) else { return nil }
        return entry.pointee.pw_uid
    }

    static func groupID(named name: String) -> gid_t? {
        guard let entry = getgrnam(name) else { return nil }
        return entry.pointee.gr_gid
    }
}

extension FileOwnership {
    /// The runtime root and sessions directory: root only, but traversable so that per-session
    /// directories can grant `nobody` access selectively.
    static let privateToRootDirectory = FileOwnership(
        owner: "root", group: "wheel", permissions: 0o750
    )
}

/// `RuntimePaths` already provides exactly what the helper needs.
extension RuntimePaths: RuntimePathsProviding {}
