import Darwin
import Foundation
import MacNetModels
import OSLog

/// Tests port availability by attempting a real `bind`.
///
/// ## Why bind rather than inspect
///
/// Ticket §14.3 requires this. Listing what is using a port — through `lsof`, `netstat`, or
/// anything else — answers a different question than the one that matters. What matters is
/// whether *this process* can take the port, and the only thing that answers that reliably is
/// trying. Inspection also cannot see a socket held by a process the helper is not allowed to
/// enumerate, and it invites parsing output that changes between OS releases.
///
/// `lsof` still has a place: naming the conflicting process makes the error message useful.
/// But it runs only after a bind has already failed, and its own failure never changes the
/// verdict.
struct SocketPortProbe: PortProbing {

    private let logger = Logger(subsystem: HelperIdentity.bundleIdentifier, category: "ports")

    func probe(_ port: ProbedPort, boundTo address: IPv4Address) -> PortAvailability {
        let socketType = port.isTCP ? SOCK_STREAM : SOCK_DGRAM
        let socketProtocol = port.isTCP ? IPPROTO_TCP : IPPROTO_UDP

        let descriptor = socket(AF_INET, socketType, Int32(socketProtocol))
        guard descriptor >= 0 else {
            return .indeterminate("socket() failed: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }

        // Without SO_REUSEADDR a socket left in TIME_WAIT by our own previous session would
        // read as a conflict, and Start would refuse for a port nothing is actually using.
        var reuse: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)
        )

        var bindAddress = sockaddr_in()
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = port.number.bigEndian
        bindAddress.sin_addr.s_addr = address.rawValue.bigEndian
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &bindAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult != 0 else { return .available }

        let error = errno
        switch error {
        case EADDRINUSE:
            logger.log("port \(port.number, privacy: .public) is in use on \(address.description, privacy: .public)")
            return .inUse

        case EADDRNOTAVAIL:
            // The address is not on any interface. During preflight that is expected — the
            // alias has not been added yet — so it says nothing about the port.
            return .indeterminate("address \(address) is not configured on this machine")

        case EACCES, EPERM:
            // Ports below 1024 need privilege. A helper that is not root has a much bigger
            // problem than this port, and reporting a conflict would misdiagnose it.
            return .indeterminate("insufficient privilege to bind port \(port.number)")

        default:
            return .indeterminate(
                "bind failed: \(String(cString: strerror(error))) (errno \(error))"
            )
        }
    }
}

/// Names the process holding a port, for the error message only.
///
/// Ticket §14.3 permits `lsof` strictly for diagnostics: its arguments are built from code
/// constants, never from user input, it is invoked by absolute path without a shell, and its
/// failure is ignored. Nothing here may change whether a start proceeds.
struct PortConflictDiagnostics: Sendable {
    let commandRunner: any CommandRunning

    func describeHolder(of port: ProbedPort) async -> String? {
        // Argument list is entirely constant except the port number, which comes from the
        // ProbedPort enum and can only be 53 or 67.
        let arguments = ["-nP", "-i", port.isTCP ? "TCP:\(port.number)" : "UDP:\(port.number)"]

        guard let result = try? await commandRunner.run(
            .lsof, arguments: arguments, currentDirectory: nil, timeout: .seconds(3)
        ), result.succeeded else {
            return nil
        }

        // First line is a header; the second names the process.
        let lines = result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return nil }

        let fields = lines[1].split(separator: " ", omittingEmptySubsequences: true)
        guard let command = fields.first else { return nil }
        let processID = fields.count > 1 ? String(fields[1]) : "?"
        return "\(command) (pid \(processID))"
    }
}
