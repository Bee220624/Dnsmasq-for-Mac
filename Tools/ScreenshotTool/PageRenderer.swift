import AppKit
import SwiftUI
import MacNetModels
import MacNetXPC

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
/// ## Why an app bundle rather than a test bundle
///
/// SwiftUI resolves `Text(LocalizedStringKey)` against `Bundle.main`. Run from a test bundle,
/// `Bundle.main` is the `xctest` tool — which carries no localizations for our keys — so every
/// string fell back to its English key no matter which language was requested. An app bundle
/// owns its own resources, so the rendered pages are localized exactly as the shipping app is.
///
/// Output goes to `build/Screenshots/<language>/`. Run with:
///
/// ```
/// make screenshots
/// ```
@MainActor
struct PageRenderer {

    private let outputRoot: URL

    init(outputRoot: URL) {
        self.outputRoot = outputRoot
    }

    /// The specification's default window size, so the output matches what a user sees on launch.
    private static let size = CGSize(width: 1180, height: 760)

    private var outputDirectory: URL { outputRoot }

    // MARK: - Environment

    /// Builds the object graph the views expect.
    ///
    /// These are the production types, constructed against a throwaway profile directory and a
    /// helper that is not installed — which is exactly the state a new user is in, and the one
    /// worth showing.
    private func makeEnvironment(helperClient: (any HelperLifecycleClient)? = nil) -> AppEnvironmentFixture {
        // Built explicitly rather than resolved from `Bundle.main`. Inside a test bundle,
        // `Bundle.main` is the xctest runner, so Settings would report version 16.0 and
        // `com.apple.dt.xctest.tool` — a screenshot that misstates the app's own identity.
        let buildEnvironment = AppEnvironment.resolve()
        let appEnvironment = AppEnvironment(
            appVersion: buildEnvironment.appVersion,
            buildNumber: buildEnvironment.buildNumber,
            bundleIdentifier: "com.bee.dnsmasqformac",
            helperLabel: "com.bee.dnsmasqformac.helper",
            machServiceName: "com.bee.dnsmasqformac.helper",
            protocolVersion: MacNetCoreInfo.protocolVersion,
            teamIdentifier: nil,
            operatingSystemVersion: {
                let version = ProcessInfo.processInfo.operatingSystemVersion
                return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            }(),
            architecture: "arm64"
        )
        let helperStatus: HelperStatusModel
        if let helperClient {
            helperStatus = HelperStatusModel(client: helperClient)
        } else {
            helperStatus = HelperStatusModel(environment: appEnvironment)
        }

        let profileDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dnsmasqformac-screenshots-\(UUID().uuidString)")

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
            .environment(\.scenePhase, .active)
            .environment(\.colorScheme, .light)
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
            FileHandle.standardError.write(Data("could not allocate a bitmap for \(name)\n".utf8))
            exit(EXIT_FAILURE)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)

        guard let png = representation.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("could not encode \(name)\n".utf8))
            exit(EXIT_FAILURE)
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

        let connectionClient = ScreenshotSessionClient()
        let connectionFixture = makeEnvironment(helperClient: connectionClient)
        defer { try? FileManager.default.removeItem(at: connectionFixture.profileDirectory) }
        await connectionFixture.profiles.load()
        connectionFixture.interfaces.refresh()
        await connectionFixture.helperStatus.refresh()

        try render("02-overview", connectionFixture) { ConnectionOverview() }
        try renderConnectionPreviews()

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

        try render("07-network-settings", fixture) {
            page { NetworkSettingsPreview() }
        }

        let expectedPages: Set<String> = [
            "01-onboarding.png", "02-overview.png", "03-leases.png", "04-logs.png",
            "05-profiles.png", "06-settings.png", "07-network-settings.png", "08-connecting.png",
            "09-connected.png", "10-ready-to-connect.png", "11-connection-failed.png", "12-reduced-motion.png",
        ]
        let written = try FileManager.default
            .contentsOfDirectory(atPath: outputDirectory.path)
            .filter { expectedPages.contains($0) }
            .sorted()
        for name in written {
            print("    \(outputDirectory.appending(path: name).path)")
        }
        guard written.count == expectedPages.count else {
            FileHandle.standardError.write(
                Data("expected twelve pages, wrote \(written)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static let previewSize = CGSize(width: 900, height: 680)
    private static let previewEpoch = Date(timeIntervalSinceReferenceDate: 0)

    /// Uses the production composition with an explicit clock, so snapshots do not depend on
    /// capture speed, service readiness, or when an off-screen window receives its next frame.
    private func connectionPreview(
        journey: ConnectionJourney, at date: Date, reducedMotion: Bool = false
    ) -> some View {
        ConnectionExperience(journey: journey, snapshotDate: date) { frame, date in
            ConnectionPreviewButton(frame: frame, date: date) {}
        }
        .environment(\.connectionReducedMotionPreview, reducedMotion)
        .environment(\.scenePhase, .active)
        .environment(\.colorScheme, .light)
        .padding(.horizontal, 32)
        .frame(width: Self.previewSize.width, height: Self.previewSize.height)
        .background(Color.white)
    }

    private func previewJourney(succeeds: Bool) -> ConnectionJourney {
        var journey = ConnectionJourney()
        journey.begin(at: Self.previewEpoch.addingTimeInterval(0.5))
        journey.resolve(
            succeeds ? .success : .failure,
            at: Self.previewEpoch.addingTimeInterval(succeeds ? 2.2 : 2.25)
        )
        return journey
    }

    private func previewHost() throws -> (NSWindow, NSHostingView<AnyView>, NSBitmapImageRep) {
        let hosting = NSHostingView(rootView: AnyView(Color.white))
        hosting.frame = CGRect(origin: .zero, size: Self.previewSize)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.previewSize.width), pixelsHigh: Int(Self.previewSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
        bitmap.size = Self.previewSize
        return (window, hosting, bitmap)
    }

    private func capture(
        journey: ConnectionJourney, at date: Date, reducedMotion: Bool = false,
        hosting: NSHostingView<AnyView>, bitmap: NSBitmapImageRep, to url: URL
    ) throws {
        hosting.rootView = AnyView(connectionPreview(journey: journey, at: date, reducedMotion: reducedMotion))
        hosting.layoutSubtreeIfNeeded()
        hosting.setNeedsDisplay(hosting.bounds)
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.coderInvalidValue)
        }
        try png.write(to: url)
    }

    func renderConnectionPreviews() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let (window, hosting, bitmap) = try previewHost()
        defer { window.contentView = nil }
        let success = previewJourney(succeeds: true)
        let failure = previewJourney(succeeds: false)
        let snapshots: [(String, ConnectionJourney, TimeInterval, Bool)] = [
            ("08-connecting", success, 2.2, false),
            ("09-connected", success, 4.0, false),
            ("10-ready-to-connect", ConnectionJourney(), 0, false),
            ("11-connection-failed", failure, 3.2, false),
            ("12-reduced-motion", success, 2.2, true),
        ]
        for (name, journey, seconds, reducedMotion) in snapshots {
            try capture(
                journey: journey, at: Self.previewEpoch.addingTimeInterval(seconds),
                reducedMotion: reducedMotion, hosting: hosting, bitmap: bitmap,
                to: outputDirectory.appending(path: "\(name).png")
            )
        }
    }

    /// Exports fixed 60 fps timeline samples. PNG encoding may run slower or faster than
    /// playback, but never stretches animation timings or requires a real network session.
    func renderConnectionAnimations() throws {
        try renderConnectionPreviews()
        let (window, hosting, bitmap) = try previewHost()
        defer { window.contentView = nil }
        let framesPerSecond = 60
        let durationSeconds = 4.2
        let frameCount = Int(durationSeconds * Double(framesPerSecond))
        for succeeds in [true, false] {
            let outcome = succeeds ? "success" : "failure"
            let framesDirectory = outputDirectory.appending(path: "\(outcome)-frames")
            try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
            let journey = previewJourney(succeeds: succeeds)
            for index in 0..<frameCount {
                try autoreleasepool {
                    let date = Self.previewEpoch.addingTimeInterval(Double(index) / Double(framesPerSecond))
                    try capture(
                        journey: index < framesPerSecond / 2 ? ConnectionJourney() : journey,
                        at: date, hosting: hosting, bitmap: bitmap,
                        to: framesDirectory.appending(path: String(format: "frame-%03d.png", index))
                    )
                }
            }
            let metadata = try JSONSerialization.data(withJSONObject: [
                "frames": frameCount, "framesPerSecond": framesPerSecond,
                "durationSeconds": durationSeconds, "beginSeconds": 0.5,
                "outcome": outcome,
            ])
            try metadata.write(to: framesDirectory.appending(path: "timing.json"))
            print("    \(framesDirectory.path): \(frameCount) frames at \(framesPerSecond) fps")
        }
    }

}

private struct NetworkSettingsPreview: View {
    @State private var profile = NetworkProfile.makeDefault(now: Date())

    var body: some View {
        ScrollView {
            NetworkSettingsCard(profile: $profile, isLocked: false)
                .padding(20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Preview-only lifecycle data. Rendering never starts a process or changes the network.
private actor ScreenshotSessionClient: HelperLifecycleClient {
    private var state: RuntimeState = .stopped

    func runtimeStatus() -> RuntimeState { state }
    func installationState() -> HelperInstallationState { .enabled }
    func handshake() -> HelperReadiness {
        .ready(HelperServiceInfoSnapshot(HelperServiceInfo(
            helperVersion: "Screenshot", protocolVersion: MacNetCoreInfo.protocolVersion,
            effectiveUID: 0, buildType: .debug, bundleIdentifier: "screenshot", engineVerification: nil
        )))
    }
    func recoverStaleState() -> RecoveryReport { RecoveryReport(outcome: .nothingToRecover) }
    func install() -> HelperInstallationState { .enabled }
    func uninstall() {}
    nonisolated func openLoginItemsSettings() {}
    func preflight(_ request: SessionStartRequest) -> PreflightReport { .pending(at: Date()) }
    func startSession(_ request: SessionStartRequest) throws(ServiceFailure) -> ActiveSession {
        throw ServiceFailure.invalidRequest("Screenshots cannot start network services.")
    }
    func stopSession(id: UUID) { state = .stopped }
    func leaseSnapshot(sessionID: UUID) -> LeaseSnapshot {
        LeaseSnapshot(sessionID: sessionID, leases: [], readAt: Date(), malformedLineCount: 0)
    }
    func logSnapshot(sessionID: UUID, after sequence: Int64) -> LogBatch {
        LogBatch(sessionID: sessionID, events: [], highestSequence: sequence)
    }
}
