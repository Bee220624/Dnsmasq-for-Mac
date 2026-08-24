import Foundation

/// The five destinations in the sidebar. Order here is the order shown (ticket §5.1) and is
/// deliberately fixed rather than data-driven — this is a tool with a fixed workflow, not a
/// configurable dashboard.
enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview
    case leases
    case logs
    case profiles
    case settings

    var id: String { rawValue }

    /// SF Symbol per ticket §5.1.
    var systemImage: String {
        switch self {
        case .overview: "network"
        case .leases: "list.bullet.rectangle"
        case .logs: "text.alignleft"
        case .profiles: "square.stack.3d.up"
        case .settings: "gearshape"
        }
    }
}

/// Owns "which page is showing". Kept separate from `AppState` so that navigation can change
/// without invalidating views that only observe service state, and vice versa.
@MainActor
@Observable
final class AppRouter {
    var selectedSection: AppSection = .overview
}
