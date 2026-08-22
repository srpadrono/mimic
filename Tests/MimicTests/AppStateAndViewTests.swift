import AppKit
import SwiftUI
import Testing
import Domain
import MockServerEngine
import Persistence
@testable import SpecImport
@testable import AppFeatures
@testable import Mimic

@Suite("AppState And Views")
@MainActor
struct AppStateAndViewTests {
    actor StubEngine: MockServerEngineProtocol {
        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation
        private(set) var startConfigurations: [ServerConfiguration] = []
        private(set) var stopCallCount = 0
        /// What the runtime actually pushed. Nothing recorded this, which is why a global delay that
        /// reached the project and stopped there had no test that could see it.
        private(set) var pushedGlobalDelays: [Int] = []

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func start(configuration: ServerConfiguration) async throws {
            startConfigurations.append(configuration)
        }

        func stop() async throws {
            stopCallCount += 1
        }

        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {
            pushedGlobalDelays.append(globalDelayMs)
        }
    }

    /// Records the activation epoch of every push, which is the one thing no other double sees.
    ///
    /// It implements the *four*-argument `updateConfiguration` rather than the three-argument one, so
    /// it observes what `MockServerRuntime` actually sends. A double that only implements the
    /// three-argument version still records a push — the protocol extension forwards to it — and
    /// would therefore pass whether or not the count was ever threaded through, which is exactly how
    /// the engine gained an activation epoch that no host passed it.
    actor EpochRecordingEngine: MockServerEngineProtocol {
        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation
        private(set) var pushedEpochs: [Int] = []

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func start(configuration: ServerConfiguration) async throws {}
        func stop() async throws {}
        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {}

        func updateConfiguration(
            endpoints: [Endpoint],
            globalDelayMs: Int,
            journey: Journey?,
            activationEpoch: Int
        ) async {
            pushedEpochs.append(activationEpoch)
        }
    }

    @discardableResult
    private func render<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 1280, height: 900),
        wait: TimeInterval = 0.1
    ) -> CGSize {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.frame = CGRect(origin: .zero, size: size)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let renderedSize = controller.view.fittingSize
        window.orderOut(nil)
        return renderedSize
    }

    private func makeAppState() throws -> AppState {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)
        let defaults = UserDefaults(suiteName: "AppStateAndViewTests.\(UUID().uuidString)")!
        let store = RecentProjectsStore(defaults: defaults)
        return AppState(projectRepository: repository, recentProjectsStore: store)
    }

    private func makeAppState(server: MockServerRuntime) throws -> AppState {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)
        let defaults = UserDefaults(suiteName: "AppStateAndViewTests.\(UUID().uuidString)")!
        let store = RecentProjectsStore(defaults: defaults)
        return AppState(server: server, projectRepository: repository, recentProjectsStore: store)
    }

    private func makeAppState(repository: any ProjectRepository) throws -> AppState {
        let defaults = UserDefaults(suiteName: "AppStateAndViewTests.\(UUID().uuidString)")!
        return AppState(
            server: MockServerRuntime(engine: StubEngine()),
            projectRepository: repository,
            recentProjectsStore: RecentProjectsStore(defaults: defaults)
        )
    }

    /// A store that refuses every write and holds nothing. Stateless, so no `@unchecked` is needed:
    /// `ProjectRepository` is `Sendable` and a struct with no stored properties satisfies that.
    ///
    /// `nonisolated` because `MimicTests` compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
    /// so an unannotated type here is `@MainActor` — and `ProjectRepository` is a nonisolated protocol
    /// declared in `Domain`. Same reason `NavigationHistory` carries it in `AppFeatures`.
    private nonisolated struct RefusingRepository: ProjectRepository {
        struct Refused: Error, LocalizedError {
            var errorDescription: String? { "the store refused the write" }
        }

        func load(id: UUID) async throws -> MockProject { throw Refused() }
        func save(_ project: MockProject) async throws { throw Refused() }
        func allProjects() async throws -> [MockProject] { [] }
        func delete(id: UUID) async throws { throw Refused() }
    }

    /// Polls `predicate` until it holds or the timeout elapses — deterministic alternative to a
    /// fixed `Task.sleep` when waiting on work dispatched to background tasks/actors.
    private func waitUntil(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(20),
        _ predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: interval)
        }
        Issue.record("Timed out waiting for condition")
    }

    private func makeImportCandidate(
        method: HTTPMethod = .post,
        path: String = "/api/v1/users",
        isSelected: Bool = true
    ) -> ImportCandidate {
        ImportCandidate(
            id: UUID(),
            isSelected: isSelected,
            method: method,
            path: path,
            suggestedName: "Imported \(method.rawValue)",
            suggestedGroupTag: "Users",
            statusCode: 201,
            responseHeaders: ["Content-Type": "application/json"],
            responseBody: #"{"id":1}"#,
            responseContentType: .json,
            bodySizeBytes: 9,
            bodySizeExceedsLimit: false,
            isDuplicate: false
        )
    }

    private func makeEndpoint() -> Endpoint {
        let scenario = Scenario(
            name: "Default",
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"ok":true}"#
        )
        return Endpoint(
            name: "Get Users",
            method: .get,
            path: "/api/v1/users",
            scenarios: [scenario],
            activeScenarioID: scenario.id,
            delayMs: 0,
            groupTag: "Users"
        )
    }

    @Test("AppState coordinates endpoint and scenario mutations")
    func appStateCoordinatesEndpointFlow() async throws {
        let appState = try makeAppState()

        appState.createProject(name: "Users API", port: 9000)
        #expect(appState.currentProject?.name == "Users API")
        #expect(appState.serverConfiguration.port == 9000)

        let endpoint = try #require(appState.addEndpoint(name: "Get Users", method: .get, path: "/api/v1/users"))
        appState.updateActiveScenario(
            endpointID: endpoint.id,
            statusCode: 202,
            headers: ["ETag": "1"],
            body: #"{"queued":true}"#
        )
        appState.updateEndpointDelay(id: endpoint.id, delayMs: 250)
        appState.updateEndpointGroupTag(id: endpoint.id, groupTag: "Accounts")
        appState.updateGlobalDelay(delayMs: 125)

        let addedScenario = try #require(appState.addScenario(endpointID: endpoint.id, name: "Unauthorized", statusCode: 401))
        appState.setActiveScenario(endpointID: endpoint.id, scenarioID: addedScenario.id)
        let copiedScenario = try #require(appState.duplicateScenario(endpointID: endpoint.id, scenarioID: addedScenario.id))
        appState.renameScenario(endpointID: endpoint.id, scenarioID: copiedScenario.id, name: "Unauthorized Copy")
        appState.deleteScenario(endpointID: endpoint.id, scenarioID: copiedScenario.id)

        let updatedEndpoint = try #require(appState.currentProject?.endpoints.first(where: { $0.id == endpoint.id }))
        let activeScenario = try #require(updatedEndpoint.scenarios.first(where: { $0.id == updatedEndpoint.activeScenarioID }))

        #expect(updatedEndpoint.delayMs == 250)
        #expect(updatedEndpoint.groupTag == "Accounts")
        #expect(appState.serverConfiguration.globalDelayMs == 125)
        #expect(activeScenario.statusCode == 401)

        let copiedEndpoint = try #require(appState.duplicateEndpoint(id: endpoint.id))
        #expect(copiedEndpoint.name == "Get Users (Copy)")

        appState.deleteEndpoint(id: copiedEndpoint.id)
        #expect(appState.currentProject?.endpoints.contains(where: { $0.id == copiedEndpoint.id }) == false)

        // `waitUntil`, not a flat 350 ms. The recents write is dispatched, so the sleep was a floor
        // every run paid and a ceiling a loaded machine could miss — and the helper that polls for it
        // was already declared thirty lines up.
        try await waitUntil { appState.recentProjects.first?.name == "Users API" }
        #expect(appState.recentProjects.count == 1)
    }

    @Test("AppState imports candidates and manages project lifecycle")
    func appStateImportsAndManagesProjects() async throws {
        let appState = try makeAppState()
        appState.createProject(name: "Imported API", port: 8081)

        appState.commitImportedCandidates([
            makeImportCandidate(),
            makeImportCandidate(method: .delete, path: "/api/v1/users/1", isSelected: false),
        ])

        #expect(appState.currentProject?.endpoints.count == 1)
        #expect(appState.currentProject?.endpoints.first?.name == "Imported POST")
        #expect(appState.currentProject?.endpoints.first?.scenarios.first?.name == "Imported")

        let originalProjectID = try #require(appState.currentProject?.id)
        appState.saveCurrentProject()
        // Each of the four waits below names the condition the next step actually depends on, rather
        // than sleeping for a round number that happens to be longer than the work usually takes.
        // (The duplicate itself no longer needs this wait — the source is the open project, so
        // `ProjectWorkspace.duplicateProject` copies the session rather than re-reading the store —
        // but the save's landing is still the fact this test is checking here.)
        try await waitUntil {
            (try? await appState.repository.load(id: originalProjectID))?.endpoints.isEmpty == false
        }

        appState.duplicateProject(id: originalProjectID)
        try await waitUntil { appState.recentProjects.contains { $0.name == "Imported API (Copy)" } }
        #expect(appState.recentProjects.contains(where: { $0.id == originalProjectID }))

        appState.closeProject()
        #expect(appState.currentProject == nil)

        appState.openProject(id: originalProjectID)
        try await waitUntil { appState.currentProject?.id == originalProjectID }

        appState.deleteProject(id: originalProjectID)
        try await waitUntil { appState.recentProjects.contains { $0.id == originalProjectID } == false }
    }

    @Test("AppState forwards mutable properties and autosave scheduling")
    func appStateForwardsMutableProperties() async throws {
        let appState = try makeAppState()
        appState.createProject(name: "Mutable API", port: 8082)

        appState.serverConfiguration = ServerConfiguration(port: 9091, globalDelayMs: 25)
        appState.portConflictAlert = PortConflictAlertData(conflictingPort: 9091)
        appState.genericStartError = "Server failed"

        let endpoint = try #require(appState.addEndpoint(name: "Users", method: .get, path: "/users"))
        // Through the command, because there is no longer any other way in. `AppState` used to carry
        // an `updateEndpoint(_:)` that wrote a whole `Endpoint` into the project directly, past the
        // path check `applyEndpointSpec` runs — a second implementation of an edit, and this line was
        // its only caller anywhere in the repository.
        let host = AppControlHost(appState: appState, repository: appState.repository)
        let renamed = await host.execute(.endpointUpdate(
            endpoint: .id(endpoint.id),
            spec: EndpointSpec(name: "Users v2", path: "/v2/users")
        ))
        #expect(renamed.ok)
        appState.scheduleAutosave()

        // The debounce is 500 ms and the write follows it, so the condition to wait for is the write
        // having landed — not a number chosen to be comfortably larger than it.
        let projectID = try #require(appState.currentProject?.id)
        try await waitUntil {
            (try? await appState.repository.load(id: projectID))?.endpoints.first?.name == "Users v2"
        }

        #expect(appState.serverConfiguration == ServerConfiguration(port: 9091, globalDelayMs: 25))
        // And it survived an unrelated mutation of the same project, because it was written *to* the
        // project. A setter that only reached the runtime's copy would have had it erased by the
        // endpoint edit above, while the getter read the project's untouched original.
        #expect(appState.currentProject?.serverConfiguration == ServerConfiguration(port: 9091, globalDelayMs: 25))
        #expect(appState.portConflictAlert?.conflictingPort == 9091)
        #expect(appState.genericStartError == "Server failed")
        #expect(appState.currentProject?.endpoints.first?.name == "Users v2")
        #expect(appState.currentProject?.endpoints.first?.path == "/v2/users")
        #expect(appState.recentProjects.first?.name == "Mutable API")
    }

    @Test("The defaults suite is chosen explicit-suite first, then test-reset, then the real one")
    func appStateResolvesDefaultsSuite() {
        // One suite decision now feeds both the recents store and the panel layout store, so this is
        // the single place that decides whether a run can see — or overwrite — real user data.
        let suiteDefaults = UserDefaults(suiteName: "AppStateStoreHelper.\(UUID().uuidString)")!
        let resetDefaults = UserDefaults(suiteName: "AppStateStoreFallback.\(UUID().uuidString)")!

        let explicit = AppState.resolveDefaults(
            environmentSuite: "explicit-suite",
            isResettingForTests: false,
            makeUserDefaults: { $0 == "explicit-suite" ? suiteDefaults : nil }
        )
        #expect(explicit === suiteDefaults, "an explicit MIMIC_DEFAULTS_SUITE wins")

        let resetting = AppState.resolveDefaults(
            environmentSuite: nil,
            isResettingForTests: true,
            makeUserDefaults: { $0.hasPrefix("devxa.Mimic.UITests.") ? resetDefaults : nil },
            now: { 42 }
        )
        #expect(resetting === resetDefaults, "a reset-for-tests run gets its own timestamped suite")

        let normal = AppState.resolveDefaults(
            environmentSuite: nil,
            isResettingForTests: false,
            makeUserDefaults: { _ in nil }
        )
        #expect(normal === UserDefaults.standard, "an ordinary launch uses the real defaults")
    }

    @Test("Both stores share one suite, so a test run cannot touch real preferences")
    func appStateStoresShareTheResolvedSuite() {
        let isolated = UserDefaults(suiteName: "AppStateShared.\(UUID().uuidString)")!
        let recents = RecentProjectsStore(defaults: isolated)
        let layout = PanelLayoutStore(defaults: isolated)

        recents.record(id: UUID(), name: "Isolated")
        layout.save(PanelLayout(requestLogHeight: 300))

        #expect(recents.load().first?.name == "Isolated")
        #expect(PanelLayoutStore(defaults: isolated).load().requestLogHeight == 300)
        // And none of it reached the real preferences.
        #expect(UserDefaults.standard.object(forKey: "panel.requestLog.height") == nil
                || PanelLayoutStore(defaults: isolated).load().requestLogHeight == 300)
    }

    /// The one test in this file whose only claim is that nothing trapped, and it says so in its name.
    ///
    /// Hosting the window is the only way to run what these views do on the way to a first frame:
    /// `ContentView` chooses between the welcome window and the workspace, `WorkspaceView` builds
    /// three split-view panes around the centre pane, and each sheet and alert below is attached to a
    /// view that has to survive being made with it already presented. None of that is reachable from
    /// a value assertion, because nothing is wrong with any value when it fails.
    ///
    /// It replaces eleven `#expect(size.width >= 0)` lines on `NSHostingController.fittingSize`, which
    /// cannot be negative. Nothing here has an honest number to assert: every one of these views is
    /// sized by the window rather than by itself, so its fitting size measures the harness. The
    /// geometry claims that can fail live beside the components that make them —
    /// `DSComponentRenderingTests` for the panel chrome, `ProjectFeatureRenderingTests` for the sheet.
    @Test("Hosting every window state does not trap during layout")
    func hostingEveryWindowStateDoesNotTrap() throws {
        let welcomeState = try makeAppState()
        render(
            ContentView()
                .environment(welcomeState)
        )

        let contentState = try makeAppState()
        contentState.createProject(name: "Workspace API", port: 8080)
        _ = contentState.addEndpoint(name: "Health", method: .get, path: "/health")
        render(
            ContentView()
                .environment(contentState)
        )

        let endpoint = makeEndpoint()
        let appState = try makeAppState()
        appState.createProject(name: "Workspace API", port: 8080)
        appState.currentProject?.endpoints = [endpoint]
        appState.requestLogs = [
            RequestLog(
                method: .get,
                path: endpoint.path,
                requestHeaders: ["Accept": "application/json"],
                requestBody: nil,
                matchedEndpointID: endpoint.id,
                matchedScenarioID: endpoint.activeScenarioID,
                responseStatusCode: 200
            ),
        ]
        appState.server.serverState = .running(port: 8080)

        render(
            CenterPaneView(content: .endpoint(nil))
                .environment(appState)
        )
        render(
            CenterPaneView(content: .endpoint(endpoint.id))
                .environment(appState)
        )
        render(
            WorkspaceView()
                .environment(appState)
        )

        try renderWorkspaceTransientStates(endpoint: endpoint)
    }

    /// Split out only to keep the smoke test above readable. Each of these opens the workspace with
    /// something already presented over it — a sheet, an alert, or a panel the user had hidden — which
    /// is a different code path from presenting it after the window exists.
    private func renderWorkspaceTransientStates(endpoint: Endpoint) throws {
        let newEndpointState = try makeAppState()
        newEndpointState.createProject(name: "Workspace API", port: 8080)
        newEndpointState.currentProject?.endpoints = [endpoint]
        newEndpointState.showNewEndpointSheet = true
        render(
            WorkspaceView(initialSelectedEndpointID: endpoint.id)
                .environment(newEndpointState)
        )

        let genericErrorState = try makeAppState()
        genericErrorState.createProject(name: "Workspace API", port: 8080)
        genericErrorState.currentProject?.endpoints = [endpoint]
        genericErrorState.genericStartError = "Server failed"
        render(
            WorkspaceView(initialSelectedEndpointID: endpoint.id)
                .environment(genericErrorState)
        )

        let portConflictState = try makeAppState()
        portConflictState.createProject(name: "Workspace API", port: 8080)
        portConflictState.currentProject?.endpoints = [endpoint]
        portConflictState.portConflictAlert = PortConflictAlertData(conflictingPort: 8080)
        render(
            WorkspaceView(initialSelectedEndpointID: endpoint.id)
                .environment(portConflictState)
        )

        let importState = try makeAppState()
        importState.createProject(name: "Workspace API", port: 8080)
        importState.currentProject?.endpoints = [endpoint]
        render(
            WorkspaceView(initialSelectedEndpointID: endpoint.id, initialShowHARImport: true)
                .environment(importState)
        )
        render(
            WorkspaceView(initialSelectedEndpointID: endpoint.id, initialShowOpenAPIImport: true)
                .environment(importState)
        )
        render(
            WorkspaceView(
                initialShowInspector: false,
                initialShowDrawer: false,
                initialSelectedEndpointID: endpoint.id
            )
            .environment(importState)
        )
    }

    @Test("AppState presentation bindings reflect and dismiss alert state")
    func appStatePresentationBindings() throws {
        let appState = try makeAppState()

        #expect(appState.isShowingPortConflict == false)
        appState.portConflictAlert = PortConflictAlertData(conflictingPort: 8080)
        #expect(appState.isShowingPortConflict)
        appState.isShowingPortConflict = false
        #expect(appState.portConflictAlert == nil)

        #expect(appState.isShowingGenericStartError == false)
        appState.genericStartError = "Boom"
        #expect(appState.isShowingGenericStartError)
        appState.isShowingGenericStartError = false
        #expect(appState.genericStartError == nil)
    }

    @Test("Mimic app scene builds")
    func mimicAppSceneBuilds() {
        let scene = MimicScene().body
        #expect(String(describing: type(of: scene)).isEmpty == false)
    }

    /// `MimicScene.init` runs on every `MimicApp.body` evaluation, so it must not build an
    /// `AppState`.
    ///
    /// It used to. Each evaluation opened the SQLite store, ran the migrations and restored the
    /// open project, and because `AppState.init` reads `currentProject` and then writes it, the
    /// write invalidated the body that was still running — an unbounded loop that re-entered this
    /// initialiser about 150 times a second and held a core at 100%. The window stopped answering
    /// the pointer, which is what it looks like from the outside: a window you cannot resize, and
    /// an app that dies if you keep trying.
    ///
    /// Constructing the scene repeatedly must therefore keep handing back the one session-owned
    /// state, never a fresh one.
    @Test("Repeatedly building the scene builds no further AppState")
    func sceneInitDoesNotRebuildAppState() {
        // Touch the session first, so the one legitimate construction is behind us.
        let expected = AppSession.shared.appState
        let created = AppState.instancesCreated

        for _ in 0..<100 {
            _ = MimicScene()
        }

        #expect(AppState.instancesCreated == created)
        #expect(AppSession.shared.appState === expected)
    }

    @Test("Mimic app helpers derive server menu behavior")
    func mimicAppHelpers() {
        #expect(MimicScene.serverToggleTitle(for: .stopped) == "Start Server")
        #expect(MimicScene.serverToggleTitle(for: .error("Boom")) == "Start Server")
        #expect(MimicScene.serverToggleTitle(for: .running(port: 8080)) == "Stop Server")
        #expect(MimicScene.shouldResetForTesting(arguments: ["-MimicResetForTesting"]))
        #expect(MimicScene.shouldResetForTesting(arguments: []) == false)

        #expect(MimicScene.canToggleServer(hasCurrentProject: false, serverState: .stopped) == false)
        #expect(MimicScene.canToggleServer(hasCurrentProject: true, serverState: .stopped))
        #expect(MimicScene.canToggleServer(hasCurrentProject: true, serverState: .running(port: 8080)))
        #expect(MimicScene.canToggleServer(hasCurrentProject: true, serverState: .error("Boom")))
        #expect(MimicScene.canToggleServer(hasCurrentProject: true, serverState: .starting) == false)
        #expect(MimicScene.canToggleServer(hasCurrentProject: true, serverState: .stopping) == false)

        var startCount = 0
        var stopCount = 0
        MimicScene.toggleServer(
            serverState: .stopped,
            start: { startCount += 1 },
            stop: { stopCount += 1 }
        )
        MimicScene.toggleServer(
            serverState: .running(port: 8080),
            start: { startCount += 1 },
            stop: { stopCount += 1 }
        )
        MimicScene.toggleServer(
            serverState: .starting,
            start: { startCount += 1 },
            stop: { stopCount += 1 }
        )

        #expect(startCount == 1)
        #expect(stopCount == 1)
    }

    @Test("UI test support default helpers use default closures safely")
    func uiTestSupportDefaultHelpers() async throws {
        let context = UITestSupport.defaultResetContext()
        #expect(context.knownTestSuites == ["com.devxa.Mimic.UITests"])
        // This process is a *unit* test, not a UI test run, so the context names no store — which is
        // exactly the state in which a reset must do nothing to the filesystem.
        #expect(context.databaseURL == nil)

        let suiteName = "UITestSupportDefaultReset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(["one"], forKey: "recentProjects")

        let store = try makeStubDatabase()

        UITestSupport.resetApp {
            (
                knownTestSuites: [suiteName],
                databaseURL: store.url,
                fileManager: .default
            )
        }

        #expect(UserDefaults(suiteName: suiteName)?.object(forKey: "recentProjects") == nil)
        #expect(FileManager.default.fileExists(atPath: store.url.path) == false)

        let hiddenWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hiddenWindow.orderOut(nil)
        let visibleWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        visibleWindow.orderFront(nil)
        defer { visibleWindow.orderOut(nil) }

        #expect(UITestSupport.hasPresentedWindow(keyWindow: nil, mainWindow: nil, windows: [hiddenWindow]) == false)
        #expect(UITestSupport.hasPresentedWindow(keyWindow: nil, mainWindow: nil, windows: [visibleWindow]))
        UITestSupport.scheduleForegroundActivationIfNeeded(isRunningUITests: true)

        #expect(defaults.object(forKey: "recentProjects") == nil)
        #expect(defaults.object(forKey: "lastOpenedProjectID") == nil)
        #expect(FileManager.default.fileExists(atPath: store.url.path) == false)
    }

    @Test("Mimic app activation and reset context helpers are injectable")
    func mimicAppActivationAndResetHelpers() async {
        var scheduledActivations = 0

        UITestSupport.scheduleForegroundActivationIfNeeded(
            isRunningUITests: false,
            enqueueActivation: { _ in scheduledActivations += 1 }
        )
        UITestSupport.scheduleForegroundActivationIfNeeded(
            isRunningUITests: true,
            enqueueActivation: { activation in
                scheduledActivations += 1
                Task { await activation() }
            },
            activation: {}
        )

        let context = UITestSupport.defaultResetContext(
            environment: [
                "MIMIC_DEFAULTS_SUITE": "com.devxa.Mimic.UITests",
                DatabaseFactory.databasePathEnvironmentKey: "/tmp/named-by-harness.sqlite",
            ]
        )

        #expect(scheduledActivations == 1)
        #expect(context.knownTestSuites == ["com.devxa.Mimic.UITests"])
        #expect(context.databaseURL == URL(fileURLWithPath: "/tmp/named-by-harness.sqlite"))
    }

    /// The seam that made the engine's activation epoch inert: it existed, `MockRouteStore` acted on
    /// it, `MockServerEngineTests` covered it, and no host passed one — so `mimic journey activate`
    /// against the already-active journey went on resuming mid-run with a green suite. Nothing below
    /// tests `MockRouteStore`; this tests only that the count leaves `AppState` and arrives, which is
    /// the half that was missing.
    @Test("Activating raises the epoch the engine is pushed; an ordinary edit does not")
    func activationEpochReachesTheEngine() async throws {
        let engine = EpochRecordingEngine()
        let appState = try makeAppState(server: MockServerRuntime(engine: engine))

        appState.createProject(name: "Epoch", port: 9861)
        let journey = try #require(appState.addJourney(name: "Retry"))
        try await waitUntil { await engine.pushedEpochs.isEmpty == false }

        // An edit — a journey was just added — must not look like an activation.
        let beforeActivation = try #require(await engine.pushedEpochs.last)

        appState.activateJourney(id: journey.id)
        try await waitUntil { await (engine.pushedEpochs.last ?? beforeActivation) > beforeActivation }
        let afterActivation = try #require(await engine.pushedEpochs.last)

        // The case the whole mechanism exists for: activating what is already active. Nothing in the
        // pushed endpoints or journey differs from the push before it, so the count is the only thing
        // that can say a run should restart.
        appState.activateJourney(id: journey.id)
        try await waitUntil { await (engine.pushedEpochs.last ?? afterActivation) > afterActivation }
        let afterReactivation = try #require(await engine.pushedEpochs.last)

        // An id naming no journey must not raise the count. It DOES still push —
        // `mutateCurrentProject` reassigns `currentProject` unconditionally, so the `didSet` fires
        // and a push goes out carrying whatever the count is — which is exactly why the count must
        // be unraised: that push is a re-push of an unchanged document, and raised it would restart
        // the run this test just started.
        //
        // Waited on the push *count* rather than on the epoch, and the invalid activation's own push
        // is why: the epoch is supposed not to move here, so a predicate about its value is true
        // before either push has landed and the assertion below would race both of them.
        let pushCountBefore = await engine.pushedEpochs.count
        appState.activateJourney(id: UUID())
        _ = appState.addJourney(name: "Unrelated")
        try await waitUntil { await engine.pushedEpochs.count > pushCountBefore }
        #expect(
            await engine.pushedEpochs.last == afterReactivation,
            "an activation that named nothing must not raise the count an ordinary edit then carries"
        )
    }

    @Test("AppState server wrappers forward to the injected server")
    func appStateServerWrappersForward() async throws {
        let engine = StubEngine()
        let server = MockServerRuntime(engine: engine)
        let appState = try makeAppState(server: server)

        appState.createProject(name: "Server API", port: 9843)
        appState.startServer()
        try await waitUntil { await engine.startConfigurations.count == 1 }
        #expect(await engine.startConfigurations.first?.port == 9843)

        appState.stopServer()
        try await waitUntil { await engine.stopCallCount == 1 }

        appState.server.serverState = .stopped
        appState.retryStartOnNextPort(from: 9843)
        try await waitUntil { await engine.startConfigurations.count == 2 }

        #expect(appState.serverConfiguration.port == 9844)
        #expect(await engine.startConfigurations.last?.port == 9844)
        // The accepted port belongs to the project, so it survives everything else the project does.
        #expect(appState.currentProject?.serverConfiguration.port == 9844)
    }

    /// The window and `mimic` have to agree about the project they are both looking at.
    ///
    /// `serverConfigure` is an ordinary project-scoped command: the executor writes it to the open
    /// project, exactly as it does for an endpoint edit. But the runtime took the configuration only
    /// when the *identity* of the open project changed, and pushed endpoints alone otherwise — so
    /// this edit reached the project and stopped there. The engine kept the old delay, the editor's
    /// "Global delay" row showed a value nothing had changed, and `mimic server status` reported the
    /// old port — a defect only possible because the runtime keeps a second copy of the
    /// configuration at all.
    @Test("A configuration change reaches the engine, not just the project")
    func serverConfigureReachesTheEngine() async throws {
        let engine = StubEngine()
        let server = MockServerRuntime(engine: engine)
        let appState = try makeAppState(server: server)

        // Two pushes, not one: `bindProjectWorkspace` applies the (empty) project during `init`, so
        // waiting for the array to be non-empty would have been satisfied before `createProject` did
        // anything at all.
        appState.createProject(name: "Checkout", port: 8080)
        try await waitUntil { await engine.pushedGlobalDelays.count >= 2 }

        appState.updateGlobalDelay(delayMs: 500)

        try await waitUntil { await engine.pushedGlobalDelays.last == 500 }
        #expect(appState.currentProject?.serverConfiguration.globalDelayMs == 500)
        // What the editor's row and `mimic server status` both read.
        #expect(appState.serverConfiguration.globalDelayMs == 500)
    }

    @Test("The welcome list is the store, ordered by the recents cache")
    func welcomeListReconcilesAgainstTheStore() {
        // The bug: the welcome window is the only way into a project — the File menu offers New and
        // Close and nothing else — and it listed a `UserDefaults` cache capped at ten. An eleventh
        // project, or any project after the cache was cleared, stayed in the database with no route
        // to it from the window at all.
        let cachedFirst = MockProject(name: "Cached first")
        let cachedSecond = MockProject(name: "Cached second")
        var forgotten = MockProject(name: "Never cached")
        var forgottenOlder = MockProject(name: "Never cached, older")
        forgotten.modifiedAt = Date(timeIntervalSince1970: 2_000)
        forgottenOlder.modifiedAt = Date(timeIntervalSince1970: 1_000)

        let cached = [
            RecentProjectEntry(id: cachedFirst.id, name: "Cached first", lastOpenedAt: Date()),
            RecentProjectEntry(id: cachedSecond.id, name: "Stale name", lastOpenedAt: Date()),
            // A project the CLI deleted while the window was open. It must not survive as a row that
            // fails when clicked.
            RecentProjectEntry(id: UUID(), name: "Deleted elsewhere", lastOpenedAt: Date()),
        ]

        let list = ProjectWorkspace.reconcile(
            cached: cached,
            stored: [forgottenOlder, cachedSecond, forgotten, cachedFirst]
        )

        // Cache order first, then everything it never knew, newest first.
        #expect(list.map(\.name) == ["Cached first", "Cached second", "Never cached", "Never cached, older"])
        // The store owns the name — a rename used to leave the old one in the cache forever.
        #expect(list[1].name == "Cached second")
        #expect(list.contains { $0.name == "Deleted elsewhere" } == false)
    }

    @Test("Nothing in the store is unreachable from the welcome list")
    func welcomeListStrandsNothing() {
        // Eleven projects against a ten-entry cache — the exact shape that used to lose one.
        let stored = (0..<11).map { MockProject(name: "Project \($0)") }
        let cached = stored.prefix(10).map {
            RecentProjectEntry(id: $0.id, name: $0.name, lastOpenedAt: Date())
        }

        let list = ProjectWorkspace.reconcile(cached: Array(cached), stored: stored)

        #expect(list.count == 11)
        #expect(Set(list.map(\.id)) == Set(stored.map(\.id)))
    }

    @Test("A running server does not outlive the project it serves")
    func serverStopsWhenTheProjectChanges() async throws {
        // The bug this covers: the engine stayed bound to the previous project's port and went on
        // reporting "running", so the window showed a live server for a configuration you had left.
        // Every entry point that swaps the open project has to stop it, so every entry point is here.
        let engine = StubEngine()
        let server = MockServerRuntime(engine: engine)
        let appState = try makeAppState(server: server)

        func startAndConfirmRunning(port: Int) async throws {
            appState.startServer()
            try await waitUntil { appState.serverState == .running(port: port) }
        }

        // Creating the *first* project must not stop anything — there is no project to leave, and a
        // spurious stop here would be indistinguishable from the bug in the other direction.
        appState.createProject(name: "First", port: 9861)
        #expect(await engine.stopCallCount == 0)

        try await startAndConfirmRunning(port: 9861)
        appState.createProject(name: "Second", port: 9862)
        try await waitUntil { await engine.stopCallCount == 1 }
        #expect(appState.serverState == .stopped)

        let secondID = try #require(appState.currentProject?.id)
        appState.closeProject()
        appState.openProject(id: secondID)
        try await waitUntil { appState.currentProject?.id == secondID }

        try await startAndConfirmRunning(port: 9862)
        appState.closeProject()
        try await waitUntil { await engine.stopCallCount == 2 }
        #expect(appState.serverState == .stopped)

        appState.openProject(id: secondID)
        try await waitUntil { appState.currentProject?.id == secondID }
        try await startAndConfirmRunning(port: 9862)
        appState.deleteProject(id: secondID)
        try await waitUntil { await engine.stopCallCount == 3 }
        #expect(appState.serverState == .stopped)
    }

    /// Writes a stand-in store and its sidecars, and returns both.
    ///
    /// The three names are literals here, and must stay literals: a fixture planted through
    /// `UITestSupport.sidecarURLs(for:)` — the function the reset deletes through — moves wherever
    /// that function moves. Reverted to the `appendingPathExtension` form it shipped with, it would
    /// plant `mimic.sqlite.wal`, the reset would delete `mimic.sqlite.wal`, both reset tests would
    /// stay green, and every real `-wal` beside a real store would go on surviving the reset — which
    /// is the WAL recovery this whole area exists to stop. `sidecarNamesAreTheOnesSQLiteWrites` holds
    /// the helper to the same three names from the other side.
    private func makeStubDatabase() throws -> (url: URL, sidecars: [URL]) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("mimic.sqlite")
        try Data("db".utf8).write(to: dbURL)
        let sidecars = ["mimic.sqlite-wal", "mimic.sqlite-shm", "mimic.sqlite-journal"].map {
            directory.appendingPathComponent($0)
        }
        for sidecar in sidecars {
            try Data("sidecar".utf8).write(to: sidecar)
        }
        return (url: dbURL, sidecars: sidecars)
    }

    /// The names themselves, pinned. `-wal`, `-shm` and `-journal` are written down in exactly two
    /// places: `sidecarURLs`, which derives the paths the reset deletes, and `makeStubDatabase`,
    /// which plants the files the reset tests expect to lose. Nothing held the second to the first
    /// except that it used to call it.
    @Test("The sidecars the reset removes are the files SQLite writes beside a store")
    func sidecarNamesAreTheOnesSQLiteWrites() {
        let store = URL(fileURLWithPath: "/tmp/mimic-uitests/mimic.sqlite")
        let sidecars = UITestSupport.sidecarURLs(for: store)

        // The suffix goes on the file name, not on the path extension. `mimic.sqlite.wal` — what
        // `appendingPathExtension` produces, and what this returned — is a file SQLite has never
        // written, so the reset removed the store and left the write-ahead log beside it.
        #expect(
            sidecars.map(\.lastPathComponent)
                == ["mimic.sqlite-wal", "mimic.sqlite-shm", "mimic.sqlite-journal"]
        )
        #expect(
            sidecars.allSatisfy {
                $0.deletingLastPathComponent().path == store.deletingLastPathComponent().path
            },
            "a sidecar has to be beside the store, since that is where SQLite recovers it from"
        )
    }

    @Test("The UI test reset clears the throwaway suite and the store it was pointed at")
    func uiTestResetHelper() throws {
        let suiteName = "UITestSupportReset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(["one"], forKey: "recentProjects")

        let store = try makeStubDatabase()

        UITestSupport.resetApp(
            knownTestSuites: [suiteName],
            databaseURL: store.url,
            fileManager: .default
        )

        #expect(UserDefaults(suiteName: suiteName)?.object(forKey: "recentProjects") == nil)
        #expect(FileManager.default.fileExists(atPath: store.url.path) == false)
        for sidecar in store.sidecars {
            #expect(
                FileManager.default.fileExists(atPath: sidecar.path) == false,
                "a sidecar SQLite would recover from survived the reset"
            )
        }
    }

    @Test("Without an explicit store, the UI test reset deletes nothing")
    func uiTestResetRefusesToGuessAStore() throws {
        // The test that would have caught the real bug. `resetApp` used to compute the database path
        // itself — Application Support, `devxa.Mimic/mimic.sqlite` — and delete it unconditionally at
        // the start of every UI test, which is the developer's own store. Now the harness has to name
        // the file, and naming nothing deletes nothing.
        let store = try makeStubDatabase()

        UITestSupport.resetApp(knownTestSuites: [], databaseURL: nil, fileManager: .default)

        #expect(FileManager.default.fileExists(atPath: store.url.path))
        for sidecar in store.sidecars {
            #expect(
                FileManager.default.fileExists(atPath: sidecar.path),
                "a reset that was given no store deleted a sidecar anyway"
            )
        }
    }

    @Test("The store to reset comes from MIMIC_DATABASE_PATH, and only from there")
    func uiTestResetResolvesStoreFromEnvironment() {
        let key = DatabaseFactory.databasePathEnvironmentKey

        #expect(UITestSupport.overriddenDatabaseURL(environment: [:]) == nil)
        // An empty value is the shape a shell exports when a variable is set but unassigned. It has
        // to read as "not set", or the reset would target `/`.
        #expect(UITestSupport.overriddenDatabaseURL(environment: [key: ""]) == nil)
        #expect(
            UITestSupport.overriddenDatabaseURL(environment: [key: "/tmp/run.sqlite"])
                == URL(fileURLWithPath: "/tmp/run.sqlite")
        )
        #expect(
            UITestSupport.overriddenDatabaseURL(environment: [key: "~/run.sqlite"])?.path
                == (("~/run.sqlite" as NSString).expandingTildeInPath)
        )
    }

    @Test("The reset arms only inside a UI test run, and only on that run's own store")
    func uiTestResetContextIsInertOutsideAUITestRun() {
        let uiTestRun = "MIMIC_DEFAULTS_SUITE"
        let dbPath = DatabaseFactory.databasePathEnvironmentKey

        // Nothing set: an ordinary launch. Nothing to delete.
        #expect(UITestSupport.defaultResetContext(environment: [:]).databaseURL == nil)

        // `MIMIC_DATABASE_PATH` alone must NOT arm the reset. `Scripts/run_cli_e2e.sh` exports exactly
        // this to point the app and the CLI at one throwaway store, and that run is not a UI test —
        // arming here would have the app delete the store the script just set up under it.
        #expect(
            UITestSupport.defaultResetContext(environment: [dbPath: "/tmp/e2e.sqlite"]).databaseURL
                == nil
        )

        // A UI test run with no explicit store gets one beside the real database, never the real
        // database itself.
        let derived = UITestSupport.defaultResetContext(
            environment: [uiTestRun: "com.devxa.Mimic.UITests"]
        ).databaseURL
        #expect(derived?.lastPathComponent == "mimic-uitests.sqlite")
        #expect(derived?.lastPathComponent != "mimic.sqlite")

        // A UI test run that names a store gets that one.
        let named = UITestSupport.defaultResetContext(
            environment: [uiTestRun: "com.devxa.Mimic.UITests", dbPath: "/tmp/x.sqlite"]
        )
        #expect(named.databaseURL == URL(fileURLWithPath: "/tmp/x.sqlite"))
        #expect(named.knownTestSuites.contains("com.devxa.Mimic.UITests"))
    }

    @Test("Preview and generated resource accessors resolve app assets")
    func previewAndResourcesResolve() {
        let previewState = AppState.preview()

        #expect(previewState.currentProject == nil)
        #expect(MimicAsset.mimicLogo.name == "MimicLogo")
        #expect(MimicResources.bundle == Bundle.module)
        #expect(MimicAsset.mimicLogo.image.isValid)
    }

    @Test("Generated asset helpers build SwiftUI image variants")
    func generatedAssetHelpersBuildSwiftUIImageVariants() {
        let asset = MimicAsset.mimicLogo
        let swiftUIImage = asset.swiftUIImage
        let image = Image(asset: asset)
        let labeledImage = Image(asset: asset, label: Text("Mimic"))
        let decorativeImage = Image(decorative: asset)

        _ = swiftUIImage
        _ = image
        _ = labeledImage
        _ = decorativeImage

        #expect(asset.name == "MimicLogo")
    }

    @Test("Default AppState init can use an isolated defaults suite")
    func defaultAppStateInitUsesTestSuite() {
        let suite = "AppStateAndViewTests.\(UUID().uuidString)"
        setenv("MIMIC_DEFAULTS_SUITE", suite, 1)
        defer { unsetenv("MIMIC_DEFAULTS_SUITE") }

        let state = AppState()

        #expect(state.recentProjects.isEmpty)
        #expect(state.currentProject == nil)
    }

    @Test("UI test activation helper can be invoked from unit tests")
    func uiTestActivationHelperBuilds() async {
        #expect(UITestSupport.isRunningUITests == false)
        await UITestSupport.performForegroundActivation()
    }

    // MARK: - Control host
    //
    // `AppControlHost` had no unit test anywhere in the repo, which is how four divergences between
    // it and the since-deleted second host shipped unnoticed — the better-tested host was the one
    // nothing in production constructed. These cover the seam a script actually hits; the sweeps in
    // `HostCommandSweepTests` cover that every command reaches an arm at all.

    @Test("A port given to `server start` is written to the project, not just to the runtime")
    func controlHostPersistsTheStartPort() async throws {
        let engine = StubEngine()
        let appState = try makeAppState(server: MockServerRuntime(engine: engine))
        let host = AppControlHost(appState: appState, repository: appState.repository)

        appState.createProject(name: "Checkout", port: 8080)

        let response = await host.execute(.serverStart(port: 9100))

        #expect(response.ok)
        // The point of the change: a port supplied to the CLI is a change to the project, so it
        // survives a reopen and cannot be overwritten by the next edit of anything else.
        #expect(appState.currentProject?.serverConfiguration.port == 9100)
        try await waitUntil { await engine.startConfigurations.last?.port == 9100 }
    }

    /// The sentence comes from `ControlMessages.reset`, not from this arm — which is what stopped it
    /// reporting `Reset all.`: true of the request, silent about the instance. The wording is pinned
    /// here because a script string-matches on it.
    @Test("Reset reports what was cleared, in ControlMessages' words")
    func controlHostResetNamesWhatWasCleared() async throws {
        let appState = try makeAppState(server: MockServerRuntime(engine: StubEngine()))
        let host = AppControlHost(appState: appState, repository: appState.repository)

        appState.createProject(name: "Checkout", port: 8080)

        let response = await host.execute(.reset(scope: .all))

        #expect(response.ok)
        // Nothing served and no journey active, so there is genuinely nothing to report.
        #expect(response.result?.message == "Reset 0 log entries.")
    }

    @Test("An invalid port is refused and leaves the project alone")
    func controlHostRejectsAnInvalidStartPort() async throws {
        let appState = try makeAppState(server: MockServerRuntime(engine: StubEngine()))
        let host = AppControlHost(appState: appState, repository: appState.repository)

        appState.createProject(name: "Checkout", port: 8080)

        let response = await host.execute(.serverStart(port: 70000))

        #expect(response.ok == false)
        #expect(appState.currentProject?.serverConfiguration.port == 8080)
    }

    /// The half a routing sweep cannot see, because a sweep's stub engine reports no cursor at all.
    ///
    /// `mimic journey advance` has to answer with the position the advance *produced*. The window's
    /// host used to dispatch the advance and then read `MockServerRuntime`'s mirror of the cursor —
    /// which the advance it had just requested had not reached — so the reply carried the position
    /// from before the command at best, and nothing at all on a script's first advance. It now awaits
    /// the engine and reports what the engine hands back, which is what this pins: an engine whose
    /// `advanceJourney()` answers with a recognisable status, and a reply carrying *that* status
    /// rather than the mirror or the not-yet-started fallback.
    @Test("`journey advance` reports the engine's answer, not the mirror")
    func controlHostAdvanceReportsTheEngineAnswer() async throws {
        let engine = AdvancingEngine()
        let appState = try makeAppState(server: MockServerRuntime(engine: engine))
        let host = AppControlHost(appState: appState, repository: appState.repository)

        appState.createProject(name: "Checkout", port: 8080)
        let added = await host.execute(.journeyAddTemplate(templateID: "payment-retry", name: "Flow"))
        #expect(added.ok)
        let activated = await host.execute(.journeyActivate(journey: .name("Flow")))
        #expect(activated.ok)

        // The mirror is deliberately left holding something else, so a reply built from it is
        // distinguishable from one built from the engine's answer.
        appState.server.journeyStatus = JourneyStatus.make(journey: Journey(name: "Stale mirror"), state: nil)

        let response = await host.execute(.journeyAdvance)

        #expect(response.ok)
        #expect(response.result?.journeyStatus?.journeyName == AdvancingEngine.answerName)
        #expect(await engine.advanceCallCount == 1)
    }

    /// The window's host used to build this reply from the *document* —
    /// `JourneyStatus.make(journey:state:nil)`, a run that has not started — whatever the engine was
    /// doing. `MockRouteStore.update` keeps the run state when the same journey with the same steps is
    /// pushed again, so a harness re-activating between test cases was told step 1 was next while the
    /// engine was mid-run. No arrangement of the engine could have changed that answer, because the
    /// engine was never asked.
    ///
    /// `MidRunEngine` makes both halves visible: it reports nothing until a journey has actually
    /// reached it, so a reply built before the push landed is distinguishable; and the cursor it
    /// reports is one nothing built from the document could produce, so a reply built from the
    /// document is distinguishable too.
    @Test("`journey activate` reports the engine's cursor, not a fresh run built from the document")
    func controlHostActivateReportsTheEngineCursor() async throws {
        let engine = MidRunEngine()
        let appState = try makeAppState(server: MockServerRuntime(engine: engine))
        let host = AppControlHost(appState: appState, repository: appState.repository)

        appState.createProject(name: "Checkout", port: 8080)
        let added = await host.execute(.journeyAddTemplate(templateID: "payment-retry", name: "Flow"))
        #expect(added.ok)

        let activated = await host.execute(.journeyActivate(journey: .name("Flow")))

        #expect(activated.ok)
        let status = try #require(activated.result?.journeyStatus)
        #expect(status.journeyName == "Flow")
        // The two markers a fabricated status could never carry: it is built from a fresh
        // `JourneyRunState`, whose cursor is 0 and which has served nothing.
        #expect(status.currentStepIndex == MidRunEngine.cursor)
        #expect(status.totalServed == MidRunEngine.totalServed)
    }

    /// An engine that answers `journeyStatus()` from the journey it was actually handed, mid-run.
    ///
    /// The `payment-retry` template has two steps, so a cursor of 1 is a real position rather than a
    /// finished run — `JourneyStatus.make` reports `currentStepIndex` as `nil` once the cursor reaches
    /// `steps.count`.
    actor MidRunEngine: MockServerEngineProtocol {
        static let cursor = 1
        static let totalServed = 3

        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation
        private var pushed: Journey?

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func start(configuration: ServerConfiguration) async throws {}
        func stop() async throws {}
        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {}

        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int, journey: Journey?) async {
            pushed = journey
        }

        func journeyStatus() async -> JourneyStatus? {
            guard let pushed else { return nil }
            return JourneyStatus.make(
                journey: pushed,
                state: JourneyRunState(
                    journeyID: pushed.id,
                    cursor: Self.cursor,
                    servedCountsByStepID: [:],
                    forceAdvancedStepIDs: [],
                    isComplete: false,
                    totalServed: Self.totalServed
                )
            )
        }
    }

    /// The channel a failed bind had none of.
    ///
    /// `serverStart` answers before the engine binds — the reply is optimistic by contract, and says
    /// so — so the failure has to survive until the caller polls. It used to leave the
    /// runtime `.stopped` with a `portConflictAlert` only `WorkspaceView` reads, so `mimic server
    /// status` answered `stopped` with no `baseURL`: the same answer as a server nobody started. Run
    /// headless — which is the same app bundle with `MIMIC_HEADLESS=1` — no alert is rendered at all,
    /// so the failure reached nobody.
    @Test("A bind that fails after `server start` has answered is reported by `server status`")
    func controlHostReportsABindThatFailed() async throws {
        let engine = FailingStartEngine(failure: .portInUse(port: 8080))
        let appState = try makeAppState(server: MockServerRuntime(engine: engine))
        let host = AppControlHost(appState: appState, repository: appState.repository)

        appState.createProject(name: "Checkout", port: 8080)

        let started = await host.execute(.serverStart(port: nil))
        #expect(started.ok, "the start is optimistic: the bind is still ahead of the reply")
        #expect(started.result?.server?.state == "starting")

        try await waitUntil { appState.serverState.isError }

        let status = await host.execute(.serverStatus)
        #expect(status.ok)
        #expect(status.result?.server?.state == "error")
        #expect(status.result?.server?.errorCode == "server.portInUse")
        #expect(status.result?.server?.message == "Port 8080 is already in use.")
        #expect(status.result?.server?.baseURL == nil)

        // …and reaches `mimic state`, which is the other command a script polls after an optimistic
        // reply, because that carries the same report.
        let state = await host.execute(.state)
        // `ControlState.server` is non-optional — the chain is already conditional through `state?`,
        // so a `?` after `server` is a compile error, not extra caution.
        #expect(state.result?.state?.server.errorCode == "server.portInUse")
        #expect(state.result?.state?.server.state == "error")
    }

    /// An engine whose `start` always throws. Typed to `MockServerError` rather than `any Error` so
    /// the value crossing into the actor is `Sendable` by its own declaration.
    actor FailingStartEngine: MockServerEngineProtocol {
        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation
        private let failure: MockServerError

        init(failure: MockServerError) {
            self.failure = failure
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func start(configuration: ServerConfiguration) async throws { throw failure }
        func stop() async throws {}
        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {}
    }

    /// An engine that answers `advanceJourney()` with a status nothing else in the test could have
    /// produced, so "the engine's answer was reported" is a claim an assertion can make.
    actor AdvancingEngine: MockServerEngineProtocol {
        static let answerName = "Advanced by the engine"

        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation
        private(set) var advanceCallCount = 0

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func start(configuration: ServerConfiguration) async throws {}
        func stop() async throws {}
        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {}

        func advanceJourney() async -> JourneyStatus? {
            advanceCallCount += 1
            return JourneyStatus.make(journey: Journey(name: Self.answerName), state: nil)
        }
    }

    /// The window's host used to store an imported document itself, as
    /// `Task { try? await repository.save(document) }` sitting beside a success envelope. The reply
    /// stays optimistic — by contract, and `ControlMessages.projectImporting`'s verb says so — but
    /// the `try?` meant a refused write reached nobody at all: `mimic project import` exited 0 on an
    /// import that never happened, and the window said nothing either.
    ///
    /// The optimistic reply is therefore *not* what this asserts. It asserts that the failure arrives
    /// on `autosaveStatus`, which is the channel the window already renders for a store failure, and
    /// that a document the store refused is not opened as though it had been stored.
    @Test("An import the store refuses reports the failure and does not open the document")
    func controlHostImportSurfacesAStoreFailure() async throws {
        let appState = try makeAppState(repository: RefusingRepository())
        let host = AppControlHost(appState: appState, repository: appState.repository)
        let document = MockProject(name: "Refused")

        let response = await host.execute(.projectImport(project: document, activate: true))

        // Optimistic by contract: the write is asynchronous and the call has to answer now.
        #expect(response.ok)
        #expect(response.result?.project?.id == document.id)

        try await waitUntil { appState.autosaveStatus == .failed("Could not import project \"Refused\".") }
        #expect(appState.currentProject == nil, "a document the store refused must not be opened")
    }

    /// The other half: when the store takes it, the document really is stored, and `activate: true`
    /// opens it — through `AppState.openProject`, so the switch stops the server the way every other
    /// project switch does.
    @Test("An accepted import is stored and opened")
    func controlHostImportStoresAndOpens() async throws {
        let appState = try makeAppState(server: MockServerRuntime(engine: StubEngine()))
        let host = AppControlHost(appState: appState, repository: appState.repository)

        let scenario = Scenario(name: "Default", statusCode: 200, body: "{}")
        let document = MockProject(
            name: "Fixture",
            endpoints: [
                Endpoint(
                    name: "Summary",
                    method: .get,
                    path: "/account-summary",
                    scenarios: [scenario],
                    activeScenarioID: scenario.id
                ),
            ]
        )

        let response = await host.execute(.projectImport(project: document, activate: true))
        #expect(response.ok)

        try await waitUntil { appState.currentProject?.id == document.id }
        let stored = try await appState.repository.load(id: document.id)
        #expect(stored.endpoints.first?.path == "/account-summary")
    }

    /// The arm that replaced `default:`. Every project-scoped command is named there, so this is the
    /// answer a caller gets rather than "unsupported" — and a command added later cannot land here by
    /// accident, because the switch no longer compiles until it is routed.
    @Test(
        "Project-scoped commands report that no project is open",
        arguments: [
            ControlCommand.endpointList,
            .journeyList,
            .serverConfigure(port: 9000, globalDelayMs: nil),
            .projectRename(name: "New name"),
        ]
    )
    func controlHostReportsNoProjectOpen(command: ControlCommand) async throws {
        let appState = try makeAppState(server: MockServerRuntime(engine: StubEngine()))
        let host = AppControlHost(appState: appState, repository: appState.repository)

        let response = await host.execute(command)

        #expect(response.ok == false)
        #expect(response.error?.code == "project.noneOpen")
    }

    // MARK: - The order writes reach the store

    /// A store that holds its first write open until a second command overtakes it, and records the
    /// order writes actually arrive in.
    ///
    /// The gate is what makes the assertion below a claim rather than a coincidence. A `save` that
    /// simply returned would let a delete issued while the import was "in flight" land after it by
    /// luck on a quick machine, and the test would pass against the very inversion it exists to
    /// catch. This one cannot return until the delete has had its chance — with a deadline, because
    /// in a correctly ordered run the delete never arrives at all until the save is done.
    private actor GatedRepository: ProjectRepository {
        /// Every write in the order it happened, with `save` split in two so an overlap is visible
        /// rather than inferred from what survived.
        private(set) var operations: [String] = []
        private var projects: [UUID: MockProject] = [:]
        private var hasGatedASave = false

        var didBeginSaving: Bool { operations.contains("save.begin") }
        func stored(_ id: UUID) -> MockProject? { projects[id] }

        func save(_ project: MockProject) async throws {
            operations.append("save.begin")
            if !hasGatedASave {
                hasGatedASave = true
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while ContinuousClock.now < deadline, !operations.contains("delete") {
                    // Every hop here releases the actor, which is what lets a delete that is not
                    // waiting its turn reach `delete(id:)` while this write is still open.
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            projects[project.id] = project
            operations.append("save.end")
        }

        func load(id: UUID) async throws -> MockProject {
            guard let project = projects[id] else { throw PersistenceError.projectNotFound(id) }
            return project
        }

        func allProjects() async throws -> [MockProject] { Array(projects.values) }

        func delete(id: UUID) async throws {
            operations.append("delete")
            projects[id] = nil
        }
    }

    /// `ProjectWorkspace.storeWrites` exists so a command a script issues *after* another cannot
    /// reach the store first, and an import — the one command that writes a whole document — was
    /// outside it: it awaited the chain without joining it, on the argument that its caller awaits
    /// the result. `AppState.importProject` did not at the time; its dispatch is now retained as
    /// `importTask` for the shutdown drain, but the write still joins the chain from the task
    /// rather than the caller — which is the window this test drives.
    ///
    /// So this is the sequence from `storeWrites`' own documentation, with an import in the place of
    /// the create: the delete took the chain as it was before the import, found nothing to wait for,
    /// removed a project the store did not have yet, and the import's insert landed behind it and
    /// put the project back.
    @Test("A delete issued while an import is in flight still reaches the store after it")
    func aDeleteCannotOvertakeAnImportInFlight() async throws {
        let repository = GatedRepository()
        let appState = try makeAppState(repository: repository)
        let document = MockProject(name: "Imported")

        appState.importProject(document, activate: false)
        // The delete has to arrive while the import's write is genuinely in flight — that is the
        // whole scenario — so it waits for the store to have taken the save in.
        try await waitUntil { await repository.didBeginSaving }
        appState.deleteProject(id: document.id)

        try await waitUntil(timeout: .seconds(5)) { await repository.operations.count == 3 }

        #expect(await repository.operations == ["save.begin", "save.end", "delete"])
        #expect(
            await repository.stored(document.id) == nil,
            "the delete removed nothing and the import put the project back behind it"
        )
    }

    /// Importing a document whose id names the **open** project replaces it — session copy included,
    /// which is the half that was missing. `ProjectWorkspace.importProject` stored the document and
    /// left the session's stale copy in place, so:
    ///
    /// - on the `--no-activate` path, the pending 500 ms autosave of the unreconciled session fired
    ///   after the import's write and overwrote the document the store had just accepted;
    /// - on the default activate path, `openProject`'s leading `flushPendingAutosave` captured the
    ///   stale session copy and dispatched exactly that save over the just-imported row.
    ///
    /// Both paths ended with the store holding the pre-import project while `mimic project import`
    /// had exited 0 — the CLI.md promise "re-importing the same document updates the project in
    /// place" made false by the session it did not update. The session is reconciled now and the
    /// superseded debounce dropped, so the sleep past the debounce window below must change nothing.
    @Test(
        "Importing over the open project supersedes the session's stale edit",
        arguments: [false, true]
    )
    func importOverTheOpenProjectWins(activate: Bool) async throws {
        let appState = try makeAppState()
        appState.createProject(name: "Original", port: 8080)
        let id = try #require(appState.currentProject?.id)
        await appState.projects.awaitPendingStoreWrites()

        // An edit still sitting in the debounce when the import arrives. The import supersedes it.
        appState.currentProject?.name = "Stale session edit"
        appState.scheduleAutosave()

        var document = try #require(appState.currentProject)
        document.name = "Imported over the open project"
        appState.importProject(document, activate: activate)

        // The import's write is chained; see it land, then wait out the debounce window in which
        // the stale session used to overwrite it.
        try await waitUntil {
            (try? await appState.repository.load(id: id))?.name == "Imported over the open project"
        }
        try await Task.sleep(for: .milliseconds(700))

        let stored = try await appState.repository.load(id: id)
        #expect(
            stored.name == "Imported over the open project",
            "the unreconciled session's autosave overwrote the imported document"
        )
        #expect(appState.currentProject?.name == "Imported over the open project")
    }

    // MARK: - An open the store refuses

    /// A store that has the project and cannot open it: the shape of a locked store, or of the one
    /// this stands in for — a document written by a build whose document schema is ahead of this
    /// one's.
    ///
    /// `allProjects` lists it, which is not an oversight but what `GRDBProjectRepository.allProjects`
    /// deliberately does: a project this build cannot open is still a project the user has, so the
    /// row is listed, clicked, and refused by `load`.
    private nonisolated struct UnreadableRepository: ProjectRepository {
        let stub: MockProject

        func load(id: UUID) async throws -> MockProject {
            throw PersistenceError.unsupportedSchemaVersion(
                name: stub.name,
                stored: MockProject.currentSchemaVersion + 1,
                supported: MockProject.currentSchemaVersion
            )
        }

        func save(_ project: MockProject) async throws {}
        func allProjects() async throws -> [MockProject] { [stub] }
        func delete(id: UUID) async throws {}
    }

    /// `openProject`'s `catch` removed the recents entry and refreshed the list, which is right for
    /// "the project is gone" and wrong for everything else. A store that is locked, or a document
    /// written by a newer build, was treated as a missing project: struck from the recents cache —
    /// which takes `lastOpenedProjectID` with it, so the app stops reopening the project on launch —
    /// with no error, no indicator, and the window still showing whatever was open before.
    @Test("An open that fails for any reason but a missing project reports it, and keeps the entry")
    func openReportsAFailureThatIsNotAMissingProject() async throws {
        let stub = MockProject(name: "Written by a newer Mimic")
        let defaults = try #require(UserDefaults(suiteName: "AppStateAndViewTests.\(UUID().uuidString)"))
        let recents = RecentProjectsStore(defaults: defaults)
        recents.record(id: stub.id, name: stub.name)
        let workspace = ProjectWorkspace(
            projectRepository: UnreadableRepository(stub: stub),
            recentProjectsStore: recents
        )

        workspace.openProject(id: stub.id)

        try await waitUntil { workspace.autosaveStatus != .idle }
        guard case let .failed(message) = workspace.autosaveStatus else {
            Issue.record("the failure was swallowed: \(workspace.autosaveStatus)")
            return
        }
        // The store's own description, verbatim: "update Mimic" is only actionable when the user can
        // see how far ahead the document is.
        #expect(message.contains("was written by a newer version of Mimic"))
        #expect(workspace.currentProject == nil)
        #expect(
            recents.load().contains { $0.id == stub.id },
            "a project the store has and cannot open is not a project the store does not have"
        )
        // The durable half of striking the entry, and the reason it is worth asserting separately:
        // `RecentProjectsStore.remove` clears this too, so the app would stop reopening the project
        // on launch — long after the failed click that caused it.
        #expect(recents.lastOpenedProjectID() == stub.id)
    }
}

/// A candidate shaped like one `SpecImport` produces, with every field the committer reads settable.
///
/// File-scope rather than a method on a suite, because both import suites below need it — and one of
/// them deliberately builds no `AppState` at all.
@MainActor
private func makeCandidate(
    method: HTTPMethod = .get,
    path: String = "/api/v1/users",
    name: String = "List users",
    groupTag: String? = "Users",
    statusCode: Int = 200,
    headers: [String: String] = ["Content-Type": "application/json"],
    graphqlOperation: String? = nil,
    isSelected: Bool = true
) -> ImportCandidate {
    ImportCandidate(
        isSelected: isSelected,
        method: method,
        path: path,
        suggestedName: name,
        suggestedGroupTag: groupTag,
        statusCode: statusCode,
        responseHeaders: headers,
        responseBody: #"{"ok":true}"#,
        responseContentType: .json,
        graphqlOperation: graphqlOperation,
        bodySizeBytes: 11,
        bodySizeExceedsLimit: false,
        isDuplicate: false
    )
}

/// The import commit pipeline, driven with no `AppState` anywhere in the test.
///
/// That is most of the point of `ImportCommitter` existing: this whole suite used to require an
/// in-memory GRDB store, a `UserDefaults` suite and a `MockServerRuntime` to ask what a bad status
/// code does to one candidate.
@Suite("Import committer")
@MainActor
struct ImportCommitterTests {

    @Test("Selected candidates become endpoints carrying their captured response")
    func selectedCandidatesBecomeEndpoints() throws {
        let outcome = ImportCommitter(project: MockProject(name: "Fixture")).commit([
            makeCandidate(method: .post, path: "/api/v1/users", name: "Create user"),
            makeCandidate(method: .delete, path: "/api/v1/users/1", isSelected: false),
        ])

        let project = try #require(outcome.project)
        #expect(project.endpoints.count == 1)

        let endpoint = try #require(project.endpoints.first)
        #expect(endpoint.name == "Create user")
        #expect(endpoint.method == .post)
        #expect(endpoint.groupTag == "Users")

        let scenario = try #require(endpoint.scenarios.first { $0.id == endpoint.activeScenarioID })
        #expect(scenario.name == "Imported")
        #expect(scenario.statusCode == 200)
        #expect(scenario.body == #"{"ok":true}"#)
        #expect(outcome.report == .cleared)
    }

    @Test("A GraphQL candidate carries its operation onto the endpoint")
    func graphqlCandidateKeepsItsOperation() throws {
        let outcome = ImportCommitter(project: MockProject(name: "Fixture")).commit([
            makeCandidate(method: .post, path: "/graphql", graphqlOperation: "GetUser"),
        ])

        // Without it the mock would answer every other call to `/graphql` as well, which is the one
        // thing a captured GraphQL endpoint must not do.
        let endpoint = try #require(outcome.project?.endpoints.first)
        #expect(endpoint.graphqlOperation == "GetUser")
    }

    @Test("Confirming with nothing ticked attempts nothing and reports nothing")
    func emptySelectionIsANoOp() {
        let outcome = ImportCommitter(project: MockProject(name: "Fixture")).commit([
            makeCandidate(isSelected: false),
        ])

        #expect(outcome.project == nil)
        // Not `.cleared`. The two are different instructions: clearing here would wipe the reason a
        // previous command left on screen, having attempted nothing of its own.
        #expect(outcome.report == .unchanged)
    }

    @Test("With no project open every candidate is refused, and said so")
    func noProjectOpenRefusesEverything() throws {
        let outcome = ImportCommitter(project: nil).commit([
            makeCandidate(),
            makeCandidate(path: "/api/v1/orders"),
        ])

        #expect(outcome.project == nil)
        #expect(outcome.report.message == "Skipped all 2 imported endpoints: no project is open.")
    }

    /// The shape a real HAR produces: a browser writes `"status": 0` for every cancelled, blocked or
    /// transport-failed request, and a session's worth of traffic normally contains several.
    @Test("A refused candidate leaves no endpoint behind, and does not take the good ones with it")
    func aRefusedCandidateRollsBackAlone() throws {
        let outcome = ImportCommitter(project: MockProject(name: "Fixture")).commit([
            makeCandidate(path: "/api/v1/cancelled", statusCode: 0),
            makeCandidate(path: "/api/v1/orders", name: "List orders"),
        ])

        let project = try #require(outcome.project)
        // An endpoint created by the first command and left without its captured response is a mock
        // nobody asked for, standing in for the one they did.
        #expect(project.endpoints.map(\.path) == ["/api/v1/orders"])

        let message = try #require(outcome.report.message)
        #expect(message.hasPrefix("Skipped 1 of 2 imported endpoints:"))
        #expect(message.contains("GET /api/v1/cancelled — Invalid status code: 0"))
    }

    @Test("A header that would split the response block is refused by name")
    func aCRLFHeaderIsRefused() throws {
        let outcome = ImportCommitter(project: MockProject(name: "Fixture")).commit([
            makeCandidate(path: "/api/v1/trace", headers: ["X-Trace": "a\r\nSet-Cookie: evil=1"]),
        ])

        // Nothing survived, so there is nothing to publish — and publishing is what pushes to the
        // engine and restarts the autosave debounce.
        #expect(outcome.project == nil)
        let message = try #require(outcome.report.message)
        #expect(message.contains(#"Invalid value for header "X-Trace""#))
    }

    @Test("The early checks are exactly the ones the executor would apply")
    func rejectionNamesTheFailingField() throws {
        #expect(ImportCommitter.rejection(for: makeCandidate()) == nil)

        let badPath = try #require(ImportCommitter.rejection(for: makeCandidate(path: "v1/things")))
        #expect(badPath.contains("Path must start with '/'"))

        let badStatus = try #require(ImportCommitter.rejection(for: makeCandidate(statusCode: 0)))
        #expect(badStatus.contains("Invalid status code: 0"))
    }
}

/// The two questions the capture sheet asks about a selection, as functions of the logs alone.
@Suite("Journey capture heuristics")
@MainActor
struct JourneyCaptureTests {

    /// Fixed timestamps rather than `Date()`: the ordering rule is the thing under test, so the
    /// clock must not be part of it.
    private static func log(
        _ path: String,
        secondsAgo: TimeInterval,
        outcome: RequestOutcome = .endpoint
    ) -> RequestLog {
        RequestLog(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 - secondsAgo),
            method: .get,
            path: path,
            responseStatusCode: 200,
            outcome: outcome
        )
    }

    @Test("A run is named after its earliest call, not the first row handed over")
    func namesAfterTheEarliestCall() {
        // Newest first, which is how the request log draws by default — so the row a user hands over
        // first is normally the last thing that happened.
        let logs = [Self.log("/checkout", secondsAgo: 0), Self.log("/cart", secondsAgo: 30)]

        #expect(JourneyCapture.name(capturing: logs) == "Cart flow")
        // And the facade `WorkspaceView` calls still answers the same thing.
        #expect(AppState.journeyName(capturing: logs) == "Cart flow")
    }

    @Test("Requests a journey already answered are not what the new flow is named after")
    func skipsJourneyAnsweredRequests() {
        let logs = [
            Self.log("/session", secondsAgo: 90, outcome: .journey),
            Self.log("/cart", secondsAgo: 30),
        ]

        #expect(JourneyCapture.name(capturing: logs) == "Cart flow")
    }

    @Test("A selection with nothing capturable in it still yields a usable name")
    func fallsBackWhenEverythingIsFiltered() {
        let nothing: [RequestLog] = []
        #expect(JourneyCapture.name(capturing: nothing) == "Captured flow")

        let onlyJourneyTraffic = [Self.log("/cart", secondsAgo: 5, outcome: .journey)]
        #expect(JourneyCapture.name(capturing: onlyJourneyTraffic) == "Captured flow")
    }

    @Test("The step count is what the journey would hold, not the number of rows")
    func stepCountCollapsesRepeatsAndDropsJourneyTraffic() {
        // Four identical polls and one request a journey already answered: one step.
        let polls = (0..<4).map { Self.log("/status", secondsAgo: TimeInterval(40 - $0 * 10)) }
        let logs = polls + [Self.log("/session", secondsAgo: 90, outcome: .journey)]

        #expect(logs.count == 5)
        #expect(JourneyCapture.stepCount(logs) == 1)
        #expect(AppState.capturedStepCount(logs) == 1)
    }
}

/// What is left on `AppState` once the pipeline, the heuristics and the flags are elsewhere: it has
/// to still answer to every name a view already writes, and it has to publish exactly when the
/// committer says something survived.
@Suite("AppState's facade over its collaborators")
@MainActor
struct AppStateFacadeTests {

    private func makeAppState() throws -> AppState {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let defaults = UserDefaults(suiteName: "AppStateFacadeTests.\(UUID().uuidString)")!
        return AppState(
            projectRepository: GRDBProjectRepository(dbQueue: dbQueue),
            recentProjectsStore: RecentProjectsStore(defaults: defaults)
        )
    }

    @Test("The presentation flags a view writes reach the object that holds them, and back")
    func presentationFlagsForwardBothWays() throws {
        let appState = try makeAppState()
        let journeyID = UUID()

        appState.showNewEndpointSheet = true
        appState.showNewProjectSheet = true
        appState.navigatorRequest = .journeys
        appState.selectedJourneyID = journeyID

        // A stored property re-added to `AppState` would shadow the forwarder and leave these at
        // their defaults, while every view carried on compiling.
        #expect(appState.presentation.showNewEndpointSheet)
        #expect(appState.presentation.showNewProjectSheet)
        #expect(appState.presentation.navigatorRequest == .journeys)
        #expect(appState.presentation.selectedJourneyID == journeyID)

        appState.presentation.navigatorRequest = .endpoints
        appState.presentation.selectedJourneyID = nil
        #expect(appState.navigatorRequest == .endpoints)
        #expect(appState.selectedJourneyID == nil)
    }

    @Test("Deleting the selected journey still moves the selection, through the forwarder")
    func deletingTheSelectedJourneyMovesTheSelection() throws {
        let appState = try makeAppState()
        appState.createProject(name: "Fixture", port: 8083)

        let first = try #require(appState.addJourney(name: "First"))
        let second = try #require(appState.addJourney(name: "Second"))
        appState.selectedJourneyID = second.id

        appState.deleteJourney(id: second.id)

        #expect(appState.selectedJourneyID == first.id)
        #expect(appState.presentation.selectedJourneyID == first.id)
    }

    @Test("A commit that lands publishes the project once")
    func commitPublishesWhatSurvived() throws {
        let appState = try makeAppState()
        appState.createProject(name: "Fixture", port: 8084)

        appState.commitImportedCandidates([makeCandidate(method: .post, name: "Create user")])

        #expect(appState.currentProject?.endpoints.map(\.name) == ["Create user"])
        #expect(appState.lastCommandError == nil)
    }

    @Test("An import in which nothing survived does not touch the open project")
    func fullyRefusedImportLeavesTheProjectAlone() throws {
        let appState = try makeAppState()
        appState.createProject(name: "Fixture", port: 8085)
        let before = try #require(appState.currentProject)

        appState.commitImportedCandidates([makeCandidate(path: "/api/v1/cancelled", statusCode: 0)])

        // Byte for byte, `modifiedAt` included: assigning `currentProject` is what pushes the whole
        // project to the engine and restarts the autosave debounce, and a refused import earns
        // neither.
        #expect(appState.currentProject == before)
        let refusal = try #require(appState.lastCommandError)
        #expect(refusal.contains("Invalid status code: 0"))
    }

    @Test("An import that selected nothing leaves the previous failure on screen")
    func emptySelectionDoesNotClearTheErrorChannel() throws {
        let appState = try makeAppState()
        appState.createProject(name: "Fixture", port: 8086)

        appState.commitImportedCandidates([makeCandidate(path: "/api/v1/cancelled", statusCode: 0)])
        let refusal = try #require(appState.lastCommandError)

        // Confirming a sheet with nothing ticked attempts nothing, so it must say nothing — clearing
        // here would erase the reason for the refusal above with a command that did no work.
        appState.commitImportedCandidates([makeCandidate(isSelected: false)])

        #expect(appState.lastCommandError == refusal)
    }

    // MARK: - The server well's width rule

    /// `WorkspaceView.wellWidth` is the whole mechanism behind the well following the panels —
    /// Xcode's flexible activity view, rebuilt as arithmetic because SwiftUI has no flexible
    /// toolbar item. Every expectation below is a literal, not the formula re-run: the budgets are
    /// 240 leading, 95 for Import, and 25 or 250 trailing depending on the inspector, and if one of
    /// them moves, the sums here go red instead of moving with it.
    @Test("The well absorbs the centre column's slack, and the inspector decides the trailing bill")
    func wellWidthFollowsTheCentreColumn() {
        // Default window, inspector open: the measured centre column is ~927pt.
        // 927 − 240 − 95 − 25 = 567.
        #expect(WorkspaceView.wellWidth(centreColumnWidth: 927, isInspectorPresented: true) == 567)

        // Same window, inspector closed: the column grows to ~1187, but the panel toggles and the
        // autosave reserve now stand over it, so the well nets almost the same width.
        // 1187 − 240 − 95 − 250 = 602.
        #expect(WorkspaceView.wellWidth(centreColumnWidth: 1187, isInspectorPresented: false) == 602)

        // **The regression this rule shipped once.** A 1024pt window with both panels open leaves a
        // ~444pt centre column, and the well is owed 84 — less than the 220pt floor this carried at
        // first. Demanding 220 there pushed the trailing toggles into AppKit's overflow menu and
        // failed three WorkspaceShellUITests on CI. The well must take what is left.
        #expect(WorkspaceView.wellWidth(centreColumnWidth: 444, isInspectorPresented: true) == 84)

        // Only zero and negative widths are floored, and the floor is small enough that granting it
        // cannot cost another item its place.
        #expect(WorkspaceView.wellWidth(centreColumnWidth: 400, isInspectorPresented: true) == 96)
        #expect(WorkspaceView.wellWidth(centreColumnWidth: 0, isInspectorPresented: false) == 96)

        // Fractional layout widths land on whole points, rounded down — a toolbar item asked for
        // 567.7pt would re-raster its hairline on the half pixel.
        #expect(WorkspaceView.wellWidth(centreColumnWidth: 927.7, isInspectorPresented: true) == 567)
    }
}
