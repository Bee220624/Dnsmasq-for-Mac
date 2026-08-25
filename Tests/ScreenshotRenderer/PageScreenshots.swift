import AppKit
import SwiftUI
import Testing
import MacNetModels

/// Renders each page to a PNG, off-screen.
///
/// ## Why NSHostingView rather than ImageRenderer
///
/// `ImageRenderer` is the obvious tool and produces a misleading picture: it draws text, icons,
/// and layout, but silently omits AppKit-backed controls. Buttons come out as the yellow
/// missing-image placeholder and `ScrollView` content does not draw at all, so an Overview
/// screenshot rendered that way is an empty page.
///
/// Hosting the view in an `NSHostingView` inside an off-screen window and calling
/// `cacheDisplay(in:to:)` uses the same drawing path a visible window would, so every control
/// renders as it actually looks. The window is never ordered front, so this still needs no
/// Screen Recording permission and still works headless.
///
/// Output goes to `build/Screenshots/`. Run with:
///
/// ```
/// make screenshots
/// ```
@Suite("Page screenshots", .serialized)
@MainActor
struct PageScreenshots {

    /// Ticket §5.1's default window size, so the output matches what a user sees on launch.
    private static let size = CGSize(width: 1180, height: 760)

    private var outputDirectory: URL {
        // Walks up from this file to the repository root, so the output lands beside the
        // project rather than somewhere inside DerivedData.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appending(path: "build/Screenshots")
    }

    // MARK: - Environment

    /// Builds the object graph the views expect.
    ///
    /// These are the production types, constructed against a throwaway profile directory and a
    /// helper that is not installed — which is exactly the state a new user is in, and the one
    /// worth showing.
    private func makeEnvironment() -> AppEnvironmentFixture {
        // Built explicitly rather than resolved from `Bundle.main`. Inside a test bundle,
        // `Bundle.main` is the xctest runner, so Settings would report version 16.0 and
        // `com.apple.dt.xctest.tool` — a screenshot that misstates the app's own identity.
        let appEnvironment = AppEnvironment(
            appVersion: "0.1.0",
            buildNumber: "1",
            bundleIdentifier: "com.bee.macnetlab",
            helperLabel: "com.bee.macnetlab.helper",
            machServiceName: "com.bee.macnetlab.helper",
            protocolVersion: MacNetCoreInfo.protocolVersion,
            teamIdentifier: nil,
            operatingSystemVersion: {
                let version = ProcessInfo.processInfo.operatingSystemVersion
                return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            }(),
            architecture: "arm64"
        )
        let helperStatus = HelperStatusModel(environment: appEnvironment)

        let profileDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "macnetlab-screenshots-\(UUID().uuidString)")

        return AppEnvironmentFixture(
            appEnvironment: appEnvironment,
            appState: AppState(),
            router: AppRouter(),
            helperStatus: helperStatus,
            interfaces: InterfaceMonitor(),
            profiles: ProfileLibrary(store: ProfileStore(directory: profileDirectory)),
            session: SessionController(client: helperStatus.client),
            leases: LeaseMonitor(client: helperStatus.client),
            logs: LogMonitor(client: helperStatus.client),
            profileDirectory: profileDirectory
        )
    }

    private struct AppEnvironmentFixture {
        let appEnvironment: AppEnvironment
        let appState: AppState
        let router: AppRouter
        let helperStatus: HelperStatusModel
        let interfaces: InterfaceMonitor
        let profiles: ProfileLibrary
        let session: SessionController
        let leases: LeaseMonitor
        let logs: LogMonitor
        let profileDirectory: URL
    }

    /// Renders a view and writes it as a PNG.
    @discardableResult
    private func render(
        _ name: String,
        _ fixture: AppEnvironmentFixture,
        @ViewBuilder _ content: () -> some View
    ) throws -> URL {
        let wrapped = content()
            .environment(fixture.appState)
            .environment(fixture.router)
            .environment(fixture.helperStatus)
            .environment(fixture.interfaces)
            .environment(fixture.profiles)
            .environment(fixture.session)
            .environment(fixture.leases)
            .environment(fixture.logs)
            .environment(\.appEnvironment, fixture.appEnvironment)
            .frame(width: Self.size.width, height: Self.size.height)
            // The renderer has no window to inherit a background from, so one is supplied —
            // otherwise the PNG would have a transparent ground and read as broken.
            .background(Color(nsColor: .windowBackgroundColor))

        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )
        let url = outputDirectory.appending(path: "\(name).png")

        let hosting = NSHostingView(rootView: AnyView(wrapped))
        hosting.frame = CGRect(origin: .zero, size: Self.size)

        // A real window, never ordered front. Some AppKit controls consult their window for
        // appearance and key state, and draw as disabled or unstyled without one.
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.appearance = NSAppearance(named: .aqua)

        // Two passes: the first resolves the layout, and the second lets anything that sized
        // itself from that layout settle before the bitmap is taken.
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else {
            Issue.record("could not allocate a bitmap for \(name)")
            return url
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)

        guard let png = representation.representation(using: .png, properties: [:]) else {
            Issue.record("could not encode \(name)")
            return url
        }
        try png.write(to: url)
        return url
    }

    /// Composes a page the way `RootView` does.
    ///
    /// The page is told to fill the remaining height. Without that, a page whose content is a
    /// `ContentUnavailableView` centres the entire stack — status bar included — and the
    /// screenshot shows dead space above the toolbar that the real window never has.
    @ViewBuilder
    private func page(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            GlobalStatusBar()
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Pages

    @Test("renders every page")
    func renderPages() async throws {
        let fixture = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: fixture.profileDirectory) }

        // Real data: profiles are loaded from a fresh store, so the shipping default profile
        // appears exactly as it would on a first launch.
        await fixture.profiles.load()
        fixture.interfaces.refresh()

        try render("01-onboarding", fixture) {
            page { OnboardingView() }
        }

        try render("02-overview", fixture) {
            page { OverviewConfigurationPreview() }
        }

        try render("03-leases", fixture) {
            page { LeasesView() }
        }

        try render("04-logs", fixture) {
            page { LogsView() }
        }

        try render("05-profiles", fixture) {
            page { ProfilesView() }
        }

        try render("06-settings", fixture) {
            page { SettingsView() }
        }

        let written = try FileManager.default
            .contentsOfDirectory(atPath: outputDirectory.path)
            .filter { $0.hasSuffix(".png") }
        #expect(written.count == 6, "expected six pages, wrote \(written.sorted())")
    }
}

/// The Overview cards, composed directly.
///
/// `OverviewView` shows onboarding until the helper is usable, which is correct behaviour but
/// means the configuration cards are unreachable on a machine without a helper installed. This
/// renders the same cards so the layout can be reviewed regardless.
private struct OverviewConfigurationPreview: View {
    @Environment(ProfileLibrary.self) private var library
    @Environment(InterfaceMonitor.self) private var interfaces

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProfileCard(isLocked: false)
                InterfaceCard(isLocked: false)

                if let profile = library.draft?.working,
                   profile.dhcpConfiguration.enabled {
                    SafetyCard(
                        interfaceName: interfaces.selected?.bsdName,
                        poolDescription: "\(profile.dhcpConfiguration.rangeStart) – "
                            + "\(profile.dhcpConfiguration.rangeEnd)",
                        isLocked: false
                    )
                }

                PreflightCard(canValidate: true) {}
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
