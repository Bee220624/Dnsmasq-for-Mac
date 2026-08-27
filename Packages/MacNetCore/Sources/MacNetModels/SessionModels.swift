import Foundation

/// The exact, frozen inputs a start request is built from.
///
/// A `NetworkProfile` is deliberately *not* usable as run parameters. A profile is a saved
/// document that the user may edit or delete at any moment, while a running session must keep
/// referring to precisely what it was started with. Snapshotting here is also what makes it
/// safe to delete a profile that a live session is using.
public struct SessionDraft: Codable, Sendable, Equatable {
    public let profileSnapshot: NetworkProfile
    public let selectedInterface: NetworkInterfaceDescriptor

    /// System resolvers captured at start, used when `upstreamMode == .system`. Resolved in
    /// the app via SystemConfiguration and passed along, because the helper must not depend
    /// on the user's dynamic store.
    public let resolvedSystemDNSServers: [IPv4Address]

    /// The user's confirmation that the selected interface is on an isolated network.
    ///
    /// The specification: never persisted, never carried across launches, and reset on stop, on
    /// interface change, and on any DHCP pool change. It lives here — inside the request —
    /// so the helper can refuse a start that lacks it, rather than trusting the UI to have
    /// asked.
    public let safetyConfirmation: Bool

    public init(
        profileSnapshot: NetworkProfile,
        selectedInterface: NetworkInterfaceDescriptor,
        resolvedSystemDNSServers: [IPv4Address],
        safetyConfirmation: Bool
    ) {
        self.profileSnapshot = profileSnapshot
        self.selectedInterface = selectedInterface
        self.resolvedSystemDNSServers = resolvedSystemDNSServers
        self.safetyConfirmation = safetyConfirmation
    }
}

/// A session the helper is actually running.
public struct ActiveSession: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let profileSnapshot: NetworkProfile
    public let interfaceSnapshot: NetworkInterfaceDescriptor
    public let startedAt: Date
    public let helperVersion: String
    public let dnsmasqVersion: String
    public let dnsmasqPID: Int32

    /// Whether *this app* added the IP alias. Only an alias recorded here as `true` is ever
    /// removed on stop, so an address the user configured themselves is never touched
    ///.
    public let aliasAddedByApp: Bool

    public init(
        id: UUID,
        profileSnapshot: NetworkProfile,
        interfaceSnapshot: NetworkInterfaceDescriptor,
        startedAt: Date,
        helperVersion: String,
        dnsmasqVersion: String,
        dnsmasqPID: Int32,
        aliasAddedByApp: Bool
    ) {
        self.id = id
        self.profileSnapshot = profileSnapshot
        self.interfaceSnapshot = interfaceSnapshot
        self.startedAt = startedAt
        self.helperVersion = helperVersion
        self.dnsmasqVersion = dnsmasqVersion
        self.dnsmasqPID = dnsmasqPID
        self.aliasAddedByApp = aliasAddedByApp
    }
}

/// The single source of truth for what the service is doing.
///
/// One enum rather than several booleans, because booleans admit states that cannot exist —
/// "running and stopping", "stopped with a live PID" — and every such combination would need
/// handling somewhere.
public enum RuntimeState: Codable, Sendable, Equatable {
    case stopped
    case preflighting
    case starting
    case running(ActiveSession)
    case stopping
    case recovering
    case failed(ServiceFailure)
}
