import Foundation
import MacNetModels
import OSLog

/// Runs a fixed executable with an argument array.
///
/// ## The environment is built, never inherited
///
/// Ticket §15.1 step 13 requires a minimal environment with the dynamic-linker injection
/// variables cleared. That is not a formality: `DYLD_INSERT_LIBRARIES` in the environment of a
/// root process means an attacker who can set it gets their code loaded into that process.
/// Rather than removing known-dangerous names from an inherited environment — a blocklist that
/// has to be kept current forever — the environment is constructed from nothing, so anything
/// not listed here is simply absent.
struct SystemCommandRunner: CommandRunning {

    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "command")

    /// The entire environment a child process gets.
    ///
    /// `PATH` is present only because some tools consult it; nothing here is ever looked up by
    /// name, since every executable is invoked by absolute path.
    private static let minimalEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]

    func run(
        _ executable: FixedExecutable,
        arguments: [String],
        currentDirectory: String?,
        timeout: Duration
    ) async throws -> CommandResult {
        let path = executable.path

        // The executable set is closed, but the *bundled* one is located from the helper's own
        // path at runtime, so its existence is worth confirming before blaming the failure on
        // something else.
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ServiceFailure(
                code: .internalError,
                title: "Missing Executable",
                message: "A required program could not be found.",
                recoverySuggestion: "Reinstall MacNetLab.",
                technicalDetails: "not executable: \(path)",
                isRetryable: false
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = Self.minimalEnvironment

        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        // Nothing here reads input; giving it /dev/null means a program that asks gets EOF
        // instead of inheriting a terminal.
        process.standardInput = FileHandle.nullDevice

        logger.debug("run \(path, privacy: .public) \(arguments.joined(separator: " "), privacy: .public)")

        do {
            try process.run()
        } catch {
            throw ServiceFailure(
                code: .internalError,
                title: "Could Not Run Program",
                message: "A required program could not be started.",
                technicalDetails: "\(path): \(error)",
                isRetryable: false
            )
        }

        // Reading must happen before waiting. A program that fills the pipe buffer blocks
        // writing, and a parent that waits first would deadlock with it forever.
        async let outputData = Self.read(standardOutput)
        async let errorData = Self.read(standardError)

        let timedOut = await Self.waitForExit(process, timeout: timeout)
        if timedOut {
            process.terminate()
            // Give termination a moment, then stop waiting either way.
            _ = await Self.waitForExit(process, timeout: .seconds(2))
        }

        let result = CommandResult(
            exitStatus: process.isRunning ? -1 : process.terminationStatus,
            standardOutput: await outputData,
            standardError: await errorData
        )

        if timedOut {
            throw ServiceFailure(
                code: .internalError,
                title: "Program Timed Out",
                message: "A required program did not finish in time.",
                technicalDetails: "\(path) exceeded \(timeout)",
                isRetryable: true
            )
        }
        return result
    }

    private static func read(_ pipe: Pipe) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                // Replacement characters rather than a failure: a program emitting invalid
                // UTF-8 should not make the operation fail (ticket §19.2).
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    /// Waits for exit, returning `true` if the timeout expired first.
    private static func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            @Sendable func finish(_ timedOut: Bool) {
                let shouldResume = resumed.withLock { alreadyResumed -> Bool in
                    guard !alreadyResumed else { return false }
                    alreadyResumed = true
                    return true
                }
                if shouldResume { continuation.resume(returning: timedOut) }
            }

            process.terminationHandler = { _ in finish(false) }

            // A process that has already exited never calls the handler, so check once after
            // installing it rather than waiting for an event that will not come.
            if !process.isRunning { finish(false) }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
                finish(true)
            }
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1_000_000_000_000_000_000
    }
}
