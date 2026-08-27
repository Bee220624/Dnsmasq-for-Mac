import Foundation
import MacNetInterfaces
import MacNetModels
import MacNetValidation
import OSLog

/// Adds and removes temporary IPv4 aliases via `/sbin/ifconfig`.
///
/// ## What this is allowed to do, and what it is not
///
/// Exactly two operations on exactly one interface: add an alias, and remove an alias it
/// added. Ticket §13.3 forbids `networksetup`, `ipconfig set`, and `route` — anything that
/// would make a *permanent* change to a macOS network service. When a session stops, the Mac
/// must be indistinguishable from before it started.
///
/// Every argument is a separate array element and every value has already been validated. No
/// shell is involved at any point (ticket §21.1).
struct InterfaceAliasManager: InterfaceAliasManaging {

    let commandRunner: any CommandRunning
    let enumerator: any InterfaceEnumerating

    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "alias")

    init(commandRunner: any CommandRunning, enumerator: any InterfaceEnumerating) {
        self.commandRunner = commandRunner
        self.enumerator = enumerator
    }

    // MARK: - Adding

    func addAlias(
        interface: String,
        address: IPv4Address,
        prefixLength: Int
    ) async throws(ServiceFailure) {
        let name = try Self.validatedInterfaceName(interface)
        guard let subnet = IPv4Subnet(containing: address, prefixLength: prefixLength) else {
            throw ServiceFailure.invalidRequest("prefix length \(prefixLength) is not permitted")
        }

        let existing = try Self.requireInterface(name, in: enumerator.enumerateInterfaces())

        // Already present with the same prefix: nothing to do, and nothing to undo later
        // (ticket §13.1). Adding it again would make the stop path remove an address that was
        // not ours to remove.
        if let entry = existing.existingEntry(for: address) {
            guard entry.prefixLength == prefixLength else {
                throw ServiceFailure(
                    code: .aliasConfigurationFailed,
                    title: "Address Already Configured Differently",
                    message: "\(address) is already on \(name), but with a different subnet mask.",
                    recoverySuggestion:
                        "Remove the existing address, or choose a different server address.",
                    technicalDetails: "existing prefix /\(entry.prefixLength.map(String.init) ?? "?"), requested /\(prefixLength)",
                    isRetryable: false
                )
            }
            logger.log("\(address.description, privacy: .public) already present on \(name, privacy: .public); not adding")
            return
        }

        // /sbin/ifconfig <interface> inet <address> netmask <mask> alias
        let result = try await Self.runIfconfig(
            commandRunner,
            [name, "inet", address.description, "netmask", subnet.netmask.description, "alias"],
            failureCode: .aliasConfigurationFailed,
            title: "Could Not Add IP Address"
        )
        _ = result

        // Ticket §13.1: confirm through getifaddrs rather than trusting a zero exit status.
        // ifconfig can succeed and still not produce the address one expects.
        let after = try Self.requireInterface(name, in: enumerator.enumerateInterfaces())
        guard after.hasAddress(address) else {
            throw ServiceFailure(
                code: .aliasConfigurationFailed,
                title: "Could Not Add IP Address",
                message: "\(address) was not present on \(name) after adding it.",
                recoverySuggestion: "Check that the interface is still connected, then try again.",
                technicalDetails: "ifconfig reported success but getifaddrs does not show the address",
                isRetryable: true
            )
        }

        logger.log("added \(address.description, privacy: .public)/\(prefixLength, privacy: .public) to \(name, privacy: .public)")
    }

    // MARK: - Removing

    func removeAlias(interface: String, address: IPv4Address) async throws(ServiceFailure) {
        let name = try Self.validatedInterfaceName(interface)

        // An interface that has disappeared is not an error (ticket §13.2). Unplugging the
        // adapter takes the alias with it, and there is nothing left to clean up.
        guard let current = enumerator.enumerateInterfaces().first(where: { $0.bsdName == name })
        else {
            logger.log("\(name, privacy: .public) is gone; alias removal is unnecessary")
            return
        }

        guard current.hasAddress(address) else {
            logger.log("\(address.description, privacy: .public) not present on \(name, privacy: .public); nothing to remove")
            return
        }

        // /sbin/ifconfig <interface> inet <address> -alias
        _ = try await Self.runIfconfig(
            commandRunner,
            [name, "inet", address.description, "-alias"],
            failureCode: .cleanupFailed,
            title: "Could Not Remove IP Address"
        )

        let after = enumerator.enumerateInterfaces().first { $0.bsdName == name }
        if after?.hasAddress(address) == true {
            // Reported, never hidden (ticket §13.2). The message has to carry enough for the
            // user to finish the job by hand.
            throw ServiceFailure(
                code: .cleanupFailed,
                title: "Could Not Remove IP Address",
                message: "\(address) is still configured on \(name).",
                recoverySuggestion:
                    "Remove it manually with:\n    sudo ifconfig \(name) inet \(address) -alias",
                technicalDetails: "the address was still present after ifconfig reported success",
                isRetryable: true
            )
        }

        logger.log("removed \(address.description, privacy: .public) from \(name, privacy: .public)")
    }

    // MARK: - Link state

    func setInterfaceUp(_ interface: String, up: Bool) async throws(ServiceFailure) {
        let name = try Self.validatedInterfaceName(interface)
        _ = try await Self.runIfconfig(
            commandRunner,
            [name, up ? "up" : "down"],
            failureCode: .aliasConfigurationFailed,
            title: up ? "Could Not Bring Interface Up" : "Could Not Return Interface To Its Previous State"
        )
        logger.log("set \(name, privacy: .public) \(up ? "up" : "down", privacy: .public)")
    }

    // MARK: - Shared

    /// Re-validates a name the helper was handed.
    ///
    /// The app validated it too, and that is irrelevant here: ticket §7 makes helper-side
    /// validation the security boundary, and this value is about to become an argument to a
    /// root-privileged program.
    private static func validatedInterfaceName(_ interface: String) throws(ServiceFailure) -> String {
        switch InterfaceName.validate(interface) {
        case .success(let name):
            return name
        case .failure(let failure):
            throw ServiceFailure(
                code: failure == .blockedByPolicy ? .interfaceNotSupported : .invalidRequest,
                title: "Interface Not Permitted",
                message: "Dnsmasq for Mac will not configure this interface.",
                technicalDetails: "\(interface.debugDescription): \(failure.rawValue)",
                isRetryable: false
            )
        }
    }

    private static func requireInterface(
        _ name: String,
        in interfaces: [NetworkInterfaceDescriptor]
    ) throws(ServiceFailure) -> NetworkInterfaceDescriptor {
        guard let found = interfaces.first(where: { $0.bsdName == name }) else {
            throw ServiceFailure(
                code: .interfaceNotFound,
                title: "Interface Not Found",
                message: "\(name) is no longer present on this Mac.",
                recoverySuggestion: "Reconnect the adapter and try again.",
                technicalDetails: nil,
                isRetryable: true
            )
        }
        return found
    }

    private static func runIfconfig(
        _ runner: any CommandRunning,
        _ arguments: [String],
        failureCode: ServiceErrorCode,
        title: String
    ) async throws(ServiceFailure) -> CommandResult {
        let result: CommandResult
        do {
            result = try await runner.run(
                .ifconfig, arguments: arguments, currentDirectory: nil, timeout: .seconds(10)
            )
        } catch let failure as ServiceFailure {
            throw failure
        } catch {
            throw ServiceFailure(
                code: failureCode, title: title,
                message: "The network configuration command could not be run.",
                technicalDetails: "\(error)", isRetryable: true
            )
        }

        guard result.succeeded else {
            throw ServiceFailure(
                code: failureCode,
                title: title,
                message: "macOS refused the network configuration change.",
                recoverySuggestion: "Check that the interface is still connected, then try again.",
                technicalDetails: "ifconfig \(arguments.joined(separator: " ")) exited "
                    + "\(result.exitStatus): \(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))",
                isRetryable: true
            )
        }
        return result
    }
}
