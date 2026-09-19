import MacNetModels
import MacNetXPC
import SwiftUI

/// Builds session requests with a resolver source selected at app launch.
///
/// Production snapshots the Mac's current resolvers when the user validates or starts a
/// session. UI automation supplies fixed documentation-only data, so a test launch never reads
/// the host's dynamic network configuration.
struct SessionRequestBuilder: Sendable {
    private let resolveSystemDNSServers: @Sendable () -> [IPv4Address]

    init(resolveSystemDNSServers: @escaping @Sendable () -> [IPv4Address] = {
        SystemResolvers.current()
    }) {
        self.resolveSystemDNSServers = resolveSystemDNSServers
    }

    func make(
        draft: ProfileDraft?,
        interface: NetworkInterfaceDescriptor?,
        isolationConfirmed: Bool
    ) -> SessionStartRequest? {
        guard let draft, let interface else { return nil }

        return SessionStartRequest(draft: SessionDraft(
            // The working copy is what the user is looking at. Starting never implicitly saves.
            profileSnapshot: draft.working,
            selectedInterface: interface,
            resolvedSystemDNSServers: resolveSystemDNSServers(),
            safetyConfirmation: isolationConfirmed
        ))
    }
}

private struct SessionRequestBuilderKey: EnvironmentKey {
    static let defaultValue = SessionRequestBuilder()
}

extension EnvironmentValues {
    var sessionRequests: SessionRequestBuilder {
        get { self[SessionRequestBuilderKey.self] }
        set { self[SessionRequestBuilderKey.self] = newValue }
    }
}
