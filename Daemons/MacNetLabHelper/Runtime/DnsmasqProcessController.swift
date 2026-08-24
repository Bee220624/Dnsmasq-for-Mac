import Darwin
import Foundation
import MacNetModels
import OSLog

/// Launches, inspects, and stops the bundled dnsmasq.
///
/// ## The signalling rule
///
/// A PID is not an identity. Between recording one and using it, the process can exit and the
/// number can be reused by something else entirely — and this code runs as root, so a signal
/// sent to the wrong PID goes wherever it is aimed. Ticket §16.2 therefore requires that
/// before *any* signal, the PID is confirmed to still be the process we launched.
///
/// `liveness(of:expectedExecutableSHA256:)` is that confirmation, and `terminate` will not
/// send anything without it. When identity cannot be established the correct action is to send
/// nothing and report a stale session — never to guess.
struct DnsmasqProcessController: ProcessControlling {

    let fileManager: RuntimeFileManager

    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "process")

    /// Environment handed to dnsmasq. Built, never inherited (ticket §15.1 step 13).
    ///
    /// The `DYLD_*` variables are absent because the environment starts empty, not because
    /// they were removed. A blocklist has to anticipate every dangerous name forever; an
    /// allowlist of one is finished.
    private static let launchEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]

    init(fileManager: RuntimeFileManager) {
        self.fileManager = fileManager
    }

    // MARK: - Launching

    func launchDnsmasq(
        configurationPath: String,
        workingDirectory: String
    ) async throws(ServiceFailure) -> LaunchedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: BundledPaths.dnsmasq)

        // Fixed arguments (ticket §9.9). The user contributes nothing here: every setting they
        // chose reached dnsmasq through the generated configuration file, which is the only
        // thing that varies.
        //
        // `--keep-in-foreground` rather than daemonising, so this process stays the parent and
        // learns immediately when dnsmasq exits. `--conf-file=` also stops dnsmasq reading
        // /etc/dnsmasq.conf, which the product must never touch.
        process.arguments = [
            "--keep-in-foreground",
            "--conf-file=\(configurationPath)",
        ]
        process.environment = Self.launchEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardInput = FileHandle.nullDevice

        // dnsmasq writes its own log to the file named in the configuration. stdout and stderr
        // carry only early startup errors — before the log file is open — which is exactly
        // when something going wrong is hardest to diagnose, so they are captured.
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw ServiceFailure(
                code: .processStartFailed,
                title: "Could Not Start dnsmasq",
                message: "The DNS and DHCP engine could not be started.",
                recoverySuggestion: "Check the log for details, then try again.",
                technicalDetails: "\(BundledPaths.dnsmasq): \(error)",
                isRetryable: true
            )
        }

        let pid = process.processIdentifier
        logger.log("launched dnsmasq pid=\(pid, privacy: .public)")

        // Drain stderr so a process that writes to it cannot block on a full pipe.
        Task.detached {
            let data = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                Logger(subsystem: HelperIdentity.bundleIdentifier, category: "dnsmasq")
                    .error("dnsmasq stderr: \(text, privacy: .public)")
            }
        }

        return LaunchedProcess(processIdentifier: pid)
    }

    // MARK: - Identity

    func liveness(
        of processIdentifier: Int32,
        expectedExecutableSHA256: String
    ) -> ProcessLiveness {
        // A PID at or below 1 is never a process we started, and signalling 0 or -1 would
        // broadcast to a process group. Refusing them here means no caller can reach that
        // mistake.
        guard processIdentifier > 1 else { return .notRunning }

        // Signal 0 performs the permission and existence check without delivering anything.
        guard kill(processIdentifier, 0) == 0 || errno == EPERM else {
            return .notRunning
        }

        guard let path = Self.executablePath(of: processIdentifier) else {
            // Alive but unreadable. Treated as a mismatch, which is the conservative branch:
            // it means nothing gets signalled.
            return .identityMismatch(actualPath: nil)
        }

        guard path == BundledPaths.dnsmasq else {
            return .identityMismatch(actualPath: path)
        }

        // The path matching is not sufficient on its own — the file at that path could have
        // been replaced since launch — so the digest recorded at start is confirmed too.
        guard let digest = try? fileManager.digest(ofFileAt: path),
              digest == expectedExecutableSHA256
        else {
            return .identityMismatch(actualPath: path)
        }

        return .runningAsExpected
    }

    /// Resolves the executable backing a PID.
    private static func executablePath(of processIdentifier: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        // proc_pidpath returns the byte count, so the buffer is sliced to it rather than
        // scanned for a terminator.
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }

    // MARK: - Stopping

    func terminate(
        processIdentifier: Int32,
        expectedExecutableSHA256: String,
        gracePeriod: Duration
    ) async throws(ServiceFailure) {
        switch liveness(
            of: processIdentifier, expectedExecutableSHA256: expectedExecutableSHA256
        ) {
        case .notRunning:
            logger.log("pid \(processIdentifier, privacy: .public) is already gone")
            return

        case .identityMismatch(let actualPath):
            // Ticket §16.2: send nothing. The PID has been recycled, and whatever holds it now
            // is some other program the user is running.
            logger.fault(
                """
                refusing to signal pid \(processIdentifier, privacy: .public): \
                it is now \(actualPath ?? "unidentifiable", privacy: .public)
                """
            )
            throw ServiceFailure(
                code: .staleSession,
                title: "Session Is Stale",
                message: "The process MacNetLab started is no longer running, and its process "
                    + "ID now belongs to something else.",
                recoverySuggestion:
                    "MacNetLab has left it alone. Choose Repair to clean up what remains.",
                technicalDetails: "pid \(processIdentifier) resolves to "
                    + (actualPath ?? "an unreadable path"),
                isRetryable: false
            )

        case .runningAsExpected:
            break
        }

        // SIGTERM first: dnsmasq closes its sockets and writes out its lease file on the way
        // down, so a graceful stop preserves the leases the user may still be looking at.
        logger.log("sending SIGTERM to \(processIdentifier, privacy: .public)")
        kill(processIdentifier, SIGTERM)

        if await waitForExit(processIdentifier, within: gracePeriod) { return }

        // Re-verify before escalating. The grace period is seconds long, which is ample time
        // for the process to exit and the PID to be reused.
        guard case .runningAsExpected = liveness(
            of: processIdentifier, expectedExecutableSHA256: expectedExecutableSHA256
        ) else {
            logger.log("pid \(processIdentifier, privacy: .public) exited during the grace period")
            return
        }

        logger.error("dnsmasq did not stop; sending SIGKILL to \(processIdentifier, privacy: .public)")
        kill(processIdentifier, SIGKILL)

        guard await waitForExit(processIdentifier, within: .seconds(2)) else {
            throw ServiceFailure(
                code: .processStopFailed,
                title: "Could Not Stop dnsmasq",
                message: "The DNS and DHCP engine did not stop when asked.",
                recoverySuggestion:
                    "Restart your Mac if the service is still running after this.",
                technicalDetails: "pid \(processIdentifier) survived SIGKILL",
                isRetryable: true
            )
        }
    }

    /// Polls for exit. Returns `false` if the process is still alive when time runs out.
    private func waitForExit(_ processIdentifier: Int32, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if kill(processIdentifier, 0) != 0, errno == ESRCH { return true }
            // 50 ms: fast enough that a normal stop feels immediate, slow enough not to spin.
            try? await Task.sleep(for: .milliseconds(50))
        }
        return kill(processIdentifier, 0) != 0 && errno == ESRCH
    }
}
