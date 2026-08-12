import AppKit
import SwiftUI
import Testing
import Domain
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

        try await Task.sleep(for: .milliseconds(350))
        #expect(appState.recentProjects.count == 1)
        #expect(appState.recentProjects.first?.name == "Users API")
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

        appState.saveCurrentProject()
        try await Task.sleep(for: .milliseconds(700))

        let originalProjectID = try #require(appState.currentProject?.id)
        appState.duplicateProject(id: originalProjectID)
        try await Task.sleep(for: .milliseconds(700))
        #expect(appState.recentProjects.contains(where: { $0.id == originalProjectID }))

        appState.closeProject()
        #expect(appState.currentProject == nil)

        appState.openProject(id: originalProjectID)
        try await Task.sleep(for: .milliseconds(300))
        #expect(appState.currentProject?.id == originalProjectID)

        appState.deleteProject(id: originalProjectID)
        try await Task.sleep(for: .milliseconds(300))
        #expect(appState.recentProjects.contains(where: { $0.id == originalProjectID }) == false)
    }

    @Test("AppState forwards mutable properties and autosave scheduling")
    func appStateForwardsMutableProperties() async throws {
        let appState = try makeAppState()
        appState.createProject(name: "Mutable API", port: 8082)

        appState.serverConfiguration = ServerConfiguration(port: 9091, globalDelayMs: 25)
        appState.portConflictAlert = PortConflictAlertData(conflictingPort: 9091)
        appState.genericStartError = "Server failed"

        let endpoint = try #require(appState.addEndpoint(name: "Users", method: .get, path: "/users"))
        var updatedEndpoint = endpoint
        updatedEndpoint.name = "Users v2"
        updatedEndpoint.path = "/v2/users"
        appState.updateEndpoint(updatedEndpoint)
        appState.scheduleAutosave()

        try await Task.sleep(for: .milliseconds(700))

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

    @Test("Content view renders welcome and workspace states")
    func contentViewRendersBothStates() throws {
        let welcomeState = try makeAppState()
        let welcomeSize = render(
            ContentView()
                .environment(welcomeState)
        )

        let workspaceState = try makeAppState()
        workspaceState.createProject(name: "Workspace API", port: 8080)
        _ = workspaceState.addEndpoint(name: "Health", method: .get, path: "/health")
        let workspaceSize = render(
            ContentView()
                .environment(workspaceState)
        )

        #expect(welcomeSize.width >= 0)
        #expect(workspaceSize.height >= 0)
    }

    @Test("Center pane and workspace render populated app state")
    func workspaceViewsRender() throws {
        let appState = try makeAppState()
        appState.createProject(name: "Workspace API", port: 8080)

        let endpoint = makeEndpoint()
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

        let centerEmptySize = render(
            CenterPaneView(content: .endpoint(nil))
                .environment(appState)
        )
        let centerSelectedSize = render(
            CenterPaneView(content: .endpoint(endpoint.id))
                .environment(appState)
        )
        let workspaceSize = render(
            WorkspaceView()
                .environment(appState)
        )

        #expect(centerEmptySize.width >= 0)
        #expect(centerSelectedSize.height >= 0)
        #expect(workspaceSize.width >= 0)
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

    @Test("Workspace view renders sheet alert and hidden panel states")
    func workspaceTransientStatesRender() throws {
        let endpoint = makeEndpoint()

        let newEndpointState = try makeAppState()
        newEndpointState.createProject(name: "Workspace API", port: 8080)
        newEndpointState.currentProject?.endpoints = [endpoint]
        newEndpointState.showNewEndpointSheet = true
        let newEndpointSize = render(
            WorkspaceView(initialSelectedEndpointID: endpoint.id)
                .environment(newEndpointState)
        )

        let genericErrorState = try makeAppState()
        genericErrorState.createProject(name: "Workspace API", port: 8080)
        genericErrorState.currentProject?.endpoints = [endpoint]
        genericErrorState.genericStartError = "Server failed"
        let genericErrorSize = render(
            WorkspaceView(initialSelectedEndpointID: endpoint.id)
                .environment(genericErrorState)
        )

        let portConflictState = try makeAppState()
        portConflictState.createProject(name: "Workspace API", port: 8080)
        portConflictState.currentProject?.endpoints = [endpoint]
        portConflictState.portConflictAlert = PortConflictAlertData(conflictingPort: 8080)
        let portConflictSize = render(
            WorkspaceView(initialSelectedEndpointID: endpoint.id)
                .environment(portConflictState)
        )

        let importState = try makeAppState()
        importState.createProject(name: "Workspace API", port: 8080)
        importState.currentProject?.endpoints = [endpoint]
        let harImportSize = render(
            WorkspaceView(initialSelectedEndpointID: endpoint.id, initialShowHARImport: true)
                .environment(importState)
        )
        let openAPIImportSize = render(
            WorkspaceView(initialSelectedEndpointID: endpoint.id, initialShowOpenAPIImport: true)
                .environment(importState)
        )
        let hiddenPanelSize = render(
            WorkspaceView(
                initialShowInspector: false,
                initialShowDrawer: false,
                initialSelectedEndpointID: endpoint.id
            )
            .environment(importState)
        )

        #expect(newEndpointSize.width >= 0)
        #expect(genericErrorSize.height >= 0)
        #expect(portConflictSize.height >= 0)
        #expect(harImportSize.width >= 0)
        #expect(openAPIImportSize.width >= 0)
        #expect(hiddenPanelSize.height >= 0)
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

        let dbURL = try makeStubDatabase()

        UITestSupport.resetApp {
            (
                knownTestSuites: [suiteName],
                databaseURL: dbURL,
                fileManager: .default
            )
        }

        #expect(UserDefaults(suiteName: suiteName)?.object(forKey: "recentProjects") == nil)
        #expect(FileManager.default.fileExists(atPath: dbURL.path) == false)

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
        #expect(FileManager.default.fileExists(atPath: dbURL.path) == false)
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
    /// old port, while the headless service — which keeps no second copy — got it right.
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

    /// Writes a stand-in store and its sidecars, and returns the main file's URL.
    private func makeStubDatabase() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("mimic.sqlite")
        try Data("db".utf8).write(to: dbURL)
        try Data("wal".utf8).write(to: dbURL.appendingPathExtension("wal"))
        try Data("shm".utf8).write(to: dbURL.appendingPathExtension("shm"))
        return dbURL
    }

    @Test("The UI test reset clears the throwaway suite and the store it was pointed at")
    func uiTestResetHelper() throws {
        let suiteName = "UITestSupportReset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(["one"], forKey: "recentProjects")

        let dbURL = try makeStubDatabase()

        UITestSupport.resetApp(
            knownTestSuites: [suiteName],
            databaseURL: dbURL,
            fileManager: .default
        )

        #expect(UserDefaults(suiteName: suiteName)?.object(forKey: "recentProjects") == nil)
        #expect(FileManager.default.fileExists(atPath: dbURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: dbURL.appendingPathExtension("wal").path) == false)
        #expect(FileManager.default.fileExists(atPath: dbURL.appendingPathExtension("shm").path) == false)
    }

    @Test("Without an explicit store, the UI test reset deletes nothing")
    func uiTestResetRefusesToGuessAStore() throws {
        // The test that would have caught the real bug. `resetApp` used to compute the database path
        // itself — Application Support, `devxa.Mimic/mimic.sqlite` — and delete it unconditionally at
        // the start of every UI test, which is the developer's own store. Now the harness has to name
        // the file, and naming nothing deletes nothing.
        let dbURL = try makeStubDatabase()

        UITestSupport.resetApp(knownTestSuites: [], databaseURL: nil, fileManager: .default)

        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        #expect(FileManager.default.fileExists(atPath: dbURL.appendingPathExtension("wal").path))
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
    // `AppControlHost` had no unit test anywhere in the repo, which is how the four divergences
    // between it and `MimicControlService` shipped unnoticed. These cover the seam a script actually
    // hits: the window's host answering the same commands the headless one does.

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

    @Test("An invalid port is refused and leaves the project alone")
    func controlHostRejectsAnInvalidStartPort() async throws {
        let appState = try makeAppState(server: MockServerRuntime(engine: StubEngine()))
        let host = AppControlHost(appState: appState, repository: appState.repository)

        appState.createProject(name: "Checkout", port: 8080)

        let response = await host.execute(.serverStart(port: 70000))

        #expect(response.ok == false)
        #expect(appState.currentProject?.serverConfiguration.port == 8080)
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
}
