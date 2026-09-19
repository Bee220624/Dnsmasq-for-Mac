#if DEBUG
import Foundation
import Testing
import MacNetModels
import MacNetXPC

@Suite("UI fixture isolation") @MainActor
struct UITestFixtureTests {
    @Test("invalid fixture selection fails closed")
    func invalidFixture() {
        #expect(throws: (any Error).self) {
            try AppDependencies.resolve(environment: .resolve(), launchEnvironment: ["DFM_UI_FIXTURE": "unknown"])
        }
        #expect(throws: (any Error).self) {
            try AppDependencies.resolve(environment: .resolve(), launchEnvironment: ["DFM_UI_FIXTURE": ""])
        }
    }

    @Test("fixture owns fresh profiles and all helper operations stay fake")
    func fixtureIsolation() async throws {
        let dependencies = try AppDependencies.resolve(
            environment: .resolve(), launchEnvironment: ["DFM_UI_FIXTURE": "ready"]
        )
        let directory = try #require(dependencies.fixtureProfileDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL)
        #expect(directory != ProfileStore.defaultDirectory())
        #expect(dependencies.helper is UITestHelperClient)
        await dependencies.profiles.load()
        #expect(dependencies.profiles.profiles.count == 1)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "profiles-v1.json").path))
        dependencies.interfaces.start()
        #expect(dependencies.interfaces.selected?.bsdName == "fixture0")
        dependencies.interfaces.stop()
        #expect(try await dependencies.helper.runtimeStatus() == .stopped)
        #expect(try await dependencies.helper.recoverStaleState().outcome == .nothingToRecover)
        let request = try #require(dependencies.sessionRequests.make(
            draft: dependencies.profiles.draft,
            interface: dependencies.interfaces.selected,
            isolationConfirmed: true
        ))
        #expect(request.draft.resolvedSystemDNSServers == [IPv4Address(rawValue: 0xC000_0235)])
        #expect(try await dependencies.helper.preflight(request).hasBlockingIssues)
        do { _ = try await dependencies.helper.startSession(request); Issue.record("fixture started service") } catch {}
        try await dependencies.helper.stopSession(id: UUID())
        dependencies.helper.openLoginItemsSettings()
        try await dependencies.helper.uninstall()
        #expect(await dependencies.helper.installationState() == .notRegistered)
        #expect(try await dependencies.helper.install() == .requiresApproval)
        #expect(try await dependencies.helper.runtimeStatus() == .stopped)
    }

    @Test("onboarding states are deterministic", arguments: ["notRegistered", "approval", "bundleIncomplete", "incompatible", "failed"])
    func fixtureStates(_ scenario: String) async throws {
        let dependencies = try AppDependencies.resolve(
            environment: .resolve(), launchEnvironment: ["DFM_UI_FIXTURE": scenario]
        )
        defer { if let directory = dependencies.fixtureProfileDirectory { try? FileManager.default.removeItem(at: directory) } }
        let model = HelperStatusModel(client: dependencies.helper)
        await model.refresh()
        switch scenario {
        case "notRegistered": #expect(model.readiness == .notInstalled(.notRegistered))
        case "approval": #expect(model.readiness == .notInstalled(.requiresApproval))
        case "bundleIncomplete": #expect(model.readiness == .notInstalled(.bundleIncomplete))
        case "incompatible":
            guard case .incompatible = model.readiness else { Issue.record("missing incompatibility"); return }
        case "failed":
            guard case .failed = model.readiness else { Issue.record("missing failure"); return }
            await model.refresh()
            guard case .ready = model.readiness else { Issue.record("retry failed"); return }
        default: Issue.record("unexpected test scenario")
        }
    }
}
#endif
