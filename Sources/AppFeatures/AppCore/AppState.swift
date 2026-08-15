import Domain
import Foundation
import Observation
import Persistence
import SpecImport

/// The root observable for a live editing session: it owns the mock server runtime and the
/// project workspace, and is the single place endpoint/scenario/journey mutations are coordinated.
///
/// Mutations are applied by `ProjectCommandExecutor` in Domain — the same pure code the CLI and the
/// control API use. The methods here keep their existing signatures for views and tests, but they no
/// longer carry their own copy of the rules, so the window and `mimic` cannot drift apart.
@Observable
@MainActor
final class AppState {
    let server: MockServerRuntime
    let projects: ProjectWorkspace
    /// The store this session reads and writes.
    ///
    /// Exposed so the control plane can reuse it. Opening a second `DatabaseQueue` on the same
    /// SQLite file — even inside one process — makes concurrent writes contend and fail with
    /// `SQLITE_BUSY`, which surfaced as an autosave that intermittently reported "Save failed".
    let repository: any ProjectRepository

    #if DEBUG
    /// How many of these have been built this process — the guard on a bug that cost 100% of a core.
    ///
    /// Constructing one is expensive: it opens the SQLite store, runs the migrations and restores
    /// the last-opened project. `MimicScene.init` used to do that inline, and SwiftUI re-runs a
    /// scene's initialiser on every `MimicApp.body` evaluation, so this climbed by about 150 a
    /// second for as long as the app was open. `sceneInitDoesNotRebuildAppState` watches it.
    ///
    /// Main-actor confined: every `AppState.init` is.
    nonisolated(unsafe) static var instancesCreated = 0
    #endif

    /// What the window is presenting and what it has selected. Held apart because none of it is a
    /// fact about the project — see ``WindowPresentation``. The four properties below forward to it
    /// with their original names and types, so every `appState.showNewProjectSheet = true` and every
    /// `$appState.selectedJourneyID` in the views still reads and writes the same thing.
    let presentation: WindowPresentation

    var showNewEndpointSheet: Bool {
        get { presentation.showNewEndpointSheet }
        set { presentation.showNewEndpointSheet = newValue }
    }
    var showNewProjectSheet: Bool {
        get { presentation.showNewProjectSheet }
        set { presentation.showNewProjectSheet = newValue }
    }
    var navigatorRequest: NavigatorTab? {
        get { presentation.navigatorRequest }
        set { presentation.navigatorRequest = newValue }
    }
    var selectedJourneyID: UUID? {
        get { presentation.selectedJourneyID }
        set { presentation.selectedJourneyID = newValue }
    }
    var serverState: ServerState { server.serverState }
    /// The open project's configuration — read from the project, not from the runtime's copy.
    ///
    /// The runtime keeps one because the engine needs a value to bind and a delay to apply, but the
    /// project is what a user edits and what `mimic server configure` writes. Reading the runtime's
    /// copy is how the editor's "Global delay" row and `mimic server status` came to report a number
    /// the project no longer held. With no project open there is nothing to read, so the runtime's
    /// value stands in — that is the welcome screen, where it is `.default`.
    /// Symmetric on purpose: what the getter reads is what the setter writes.
    ///
    /// A getter sourced from the project and a setter that wrote only the runtime would compile, read
    /// naturally, and silently discard every write while a project was open — and the next mutation
    /// of anything else would overwrite the runtime's copy too, erasing it twice over. Writing the
    /// project first is also what pushes the change to the engine, because `currentProject`'s `didSet`
    /// applies the project; the second line is the fallback for the welcome screen, where there is no
    /// project to hold the value.
    var serverConfiguration: ServerConfiguration {
        get { currentProject?.serverConfiguration ?? server.serverConfiguration }
        set {
            if currentProject != nil {
                currentProject?.serverConfiguration = newValue
                // Every other project mutation reaches the disk through `run`, which schedules this.
                // Writing the project directly and not scheduling it would store the change in memory
                // and lose it on reopen — the same half-applied state this property was made
                // symmetric to avoid, one layer down.
                projects.scheduleAutosave()
            }
            server.serverConfiguration = newValue
        }
    }
    var requestLogs: [RequestLog] {
        get { server.requestLogs }
        set { server.requestLogs = newValue }
    }
    var portConflictAlert: PortConflictAlertData? {
        get { server.portConflictAlert }
        set { server.portConflictAlert = newValue }
    }
    var genericStartError: String? {
        get { server.genericStartError }
        set { server.genericStartError = newValue }
    }

    /// Why the last start attempt failed, or `nil` when it did not fail.
    ///
    /// Read-only, and deliberately not one of the two alert channels above: those are cleared by the
    /// window when the user dismisses them, and a headless instance renders neither. This is what
    /// `AppControlHost` reports on `mimic server status`. See ``MockServerRuntime/startFailure``.
    var serverStartFailure: ControlError? { server.startFailure }

    /// Presentation binding for the port-conflict alert — setting `false` dismisses it.
    /// Lets views bind directly (`$appState.isShowingPortConflict`) instead of building ad-hoc `Binding(get:set:)`.
    var isShowingPortConflict: Bool {
        get { server.portConflictAlert != nil }
        set { if !newValue { server.portConflictAlert = nil } }
    }

    /// Presentation binding for the generic server-error alert — setting `false` dismisses it.
    var isShowingGenericStartError: Bool {
        get { server.genericStartError != nil }
        set { if !newValue { server.genericStartError = nil } }
    }
    /// The open project. Writing it publishes through `ProjectWorkspace`'s one door.
    ///
    /// Every edit the window and the control plane make lands here — ``run(_:)``,
    /// ``commitImportedCandidates(_:)``, ``serverConfiguration``'s setter and `AppControlHost`'s
    /// project-scoped arm — and this setter used to assign the workspace's property directly, past
    /// the supersede ticket a publish owes an open still in flight. See
    /// ``ProjectWorkspace/openGeneration`` for what that cost.
    var currentProject: MockProject? {
        get { projects.currentProject }
        set { projects.setCurrentProject(newValue, isRestoring: false) }
    }
    var recentProjects: [RecentProjectEntry] { projects.recentProjects }
    var autosaveStatus: AutosaveStatus { projects.autosaveStatus }

    // MARK: - Journeys

    var journeys: [Journey] { currentProject?.journeys ?? [] }
    var activeJourney: Journey? { currentProject?.activeJourney }

    /// Live run progress for the active journey, refreshed from the engine.
    ///
    /// The engine owns the cursor while it is serving, so this is a published mirror rather than a
    /// computed property: reading it would otherwise require an `await` from a view body.
    var activeJourneyStatus: JourneyStatus? { server.journeyStatus }

    /// Designated initializer — the single composition point for a session.
    /// `server` is injectable so tests can substitute a fake-engine-backed runtime, and the
    /// repository is the `ProjectRepository` port (not a concrete store) so persistence is swappable.
    init(
        server: MockServerRuntime = MockServerRuntime(),
        projectRepository: any ProjectRepository,
        recentProjectsStore: RecentProjectsStore,
        panelLayoutStore: PanelLayoutStore = PanelLayoutStore(),
        presentation: WindowPresentation = WindowPresentation()
    ) {
        #if DEBUG
        Self.instancesCreated += 1
        #endif
        self.server = server
        self.panelLayoutStore = panelLayoutStore
        self.presentation = presentation
        repository = projectRepository
        projects = ProjectWorkspace(
            projectRepository: projectRepository,
            recentProjectsStore: recentProjectsStore
        )
        bindProjectWorkspace()
        _ = projects.loadLastOpenedProject()
    }

    /// Production composition root — wires GRDB persistence and the live recent-projects store.
    ///
    /// The store used to be opened with `try!`, so a database that was locked, unwritable, or on a
    /// full disk killed the app on launch with a fatal error. Launching right after quitting hit
    /// exactly that. A local development tool should not take its own life over a busy file: it now
    /// falls back to an in-memory store and says so, which leaves the app usable and the failure
    /// impossible to miss.
    convenience init() {
        let isResettingForTests = ProcessInfo.processInfo.arguments.contains("-MimicResetForTesting")
        let opened = Self.openStore()
        let defaults = Self.resolveDefaults(
            environmentSuite: ProcessInfo.processInfo.environment["MIMIC_DEFAULTS_SUITE"],
            isResettingForTests: isResettingForTests
        )
        self.init(
            projectRepository: opened.repository,
            recentProjectsStore: RecentProjectsStore(defaults: defaults),
            // Same defaults instance as recents, so a UI test run cannot inherit — or overwrite —
            // the developer's real window arrangement.
            panelLayoutStore: PanelLayoutStore(defaults: defaults)
        )
        storeFailure = opened.failure
    }

    /// Why the on-disk store could not be opened, or `nil` when it opened normally.
    ///
    /// Non-nil means the session is running in memory: everything works, and nothing survives quit.
    var storeFailure: String?

    var isShowingStoreFailure: Bool {
        get { storeFailure != nil }
        set { if !newValue { storeFailure = nil } }
    }

    /// Where the panels were left last time. Held here because this is the one place that knows
    /// which `UserDefaults` suite the session is running against.
    let panelLayoutStore: PanelLayoutStore

    /// The store for this session — the real one, or a UI test run's own.
    ///
    /// A UI test run must never open `mimic.sqlite`. It used to: the suite launched the real app,
    /// which opened the real database, and the reset helper then deleted that file at the start of
    /// every test. Running the suite locally therefore destroyed the developer's projects, silently,
    /// and left the runner's own fixtures in their place.
    ///
    /// `UITestSupport.databaseURL` names the run's store, and it is the same value the reset deletes,
    /// so the file the suite opens and the file the suite removes cannot drift apart.
    private static func openStore() -> ProjectStore.Opened {
        #if DEBUG
        if let testDatabaseURL = UITestSupport.databaseURL() {
            let opened = ProjectStore.open(makeOnDisk: {
                try DatabaseFactory.makeAppDatabaseQueue(
                    environment: [DatabaseFactory.databasePathEnvironmentKey: testDatabaseURL.path]
                )
            })
            // A run that asked for `MIMIC_FAIL_PROJECT_WRITES=1` gets a store whose writes throw, so
            // the autosave indicator's `.failed` arm becomes reachable — see
            // `UITestSupport.projectRepositoryFailingWritesIfRequested`, which is what decides.
            // Applied *around* the opened store rather than instead of it: the session still opens
            // the run's own database, still reads from it, and still reports a real open failure
            // through `Opened.failure`. Only the writes are refused.
            return ProjectStore.Opened(
                repository: UITestSupport.projectRepositoryFailingWritesIfRequested(opened.repository),
                failure: opened.failure
            )
        }
        #endif
        return ProjectStore.open()
    }

    /// The defaults suite for this session: a test-provided one, a fresh one when resetting for
    /// tests, or the real one.
    static func resolveDefaults(
        environmentSuite: String?,
        isResettingForTests: Bool,
        makeUserDefaults: (String) -> UserDefaults? = UserDefaults.init(suiteName:),
        now: () -> Int = { Int(Date().timeIntervalSince1970) }
    ) -> UserDefaults {
        if let suite = environmentSuite, let testDefaults = makeUserDefaults(suite) {
            return testDefaults
        }
        if isResettingForTests {
            return makeUserDefaults("devxa.Mimic.UITests.\(now())") ?? .standard
        }
        return .standard
    }

    #if DEBUG
    static func preview() -> AppState {
        let dbQueue = try! DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)
        let store = RecentProjectsStore(defaults: UserDefaults(suiteName: "preview.\(UUID().uuidString)")!)
        return AppState(projectRepository: repository, recentProjectsStore: store)
    }
    #endif

    func startServer() { server.startServer() }
    func stopServer() { server.stopServer() }
    /// Accepts the next port after a conflict, and writes it to the project on the way.
    ///
    /// The port a user accepts here is a setting, not a runtime detail: it only lived on the runtime,
    /// so it was lost the next time the project was opened, and — now that the project is what the
    /// runtime is applied from — it would be overwritten by the next edit of anything else. One
    /// command puts it where it belongs; the runtime call then clears the alert and starts.
    func retryStartOnNextPort(from port: Int) {
        // Only start once the port is stored. A conflict on 65535 makes the next port 65536, which
        // the validator rejects — and starting anyway would leave the runtime bound to a port the
        // project does not have, which is the divergence this whole path exists to close. `run` has
        // already put the reason in `lastCommandError`, so the user is told rather than left with a
        // server that quietly did not start.
        guard run(.serverConfigure(port: port + 1, globalDelayMs: nil)) != nil else { return }
        server.retryStartOnNextPort(from: port)
    }

    // MARK: - Endpoints

    func addEndpoint(name: String, method: HTTPMethod = .get, path: String) -> Endpoint? {
        run(.endpointCreate(name: name, method: method, path: path, spec: nil))?.endpoint
    }

    // There is deliberately no `updateEndpoint(_ updated: Endpoint)`. One used to sit here, writing a
    // whole `Endpoint` into the open project through `mutateCurrentProject` — a second way to mutate
    // the document, past the checks `ProjectCommandExecutor.applyEndpointSpec` runs on
    // `.endpointUpdate` (the path validator, and the delay's own `>= 0`). Its comment justified itself
    // by saying the editor produced whole values; `EndpointEditorActions` carries no name or path
    // action, so the only caller in the repository was a test. Every field edit is `.endpointUpdate`
    // with an `EndpointSpec`, which is what `updateEndpointDelay` and `updateEndpointGroupTag` below
    // already do.

    func deleteEndpoint(id: UUID) {
        _ = run(.endpointDelete(endpoint: .id(id)))
    }

    func duplicateEndpoint(id: UUID) -> Endpoint? {
        run(.endpointDuplicate(endpoint: .id(id)))?.endpoint
    }

    func updateActiveScenario(
        endpointID: UUID,
        statusCode: Int? = nil,
        headers: [String: String]? = nil,
        body: String? = nil
    ) {
        guard let endpoint = currentProject?.endpoints.first(where: { $0.id == endpointID }),
              let activeID = endpoint.activeScenarioID
        else { return }

        _ = run(.scenarioUpdate(
            endpoint: .id(endpointID),
            scenario: .id(activeID),
            spec: ScenarioSpec(statusCode: statusCode, headers: headers, body: body)
        ))
    }

    func updateEndpointDelay(id: UUID, delayMs: Int) {
        _ = run(.endpointUpdate(endpoint: .id(id), spec: EndpointSpec(delayMs: delayMs)))
    }

    func updateEndpointGroupTag(id: UUID, groupTag: String?) {
        // The executor treats an empty string as "clear", which is also how the CLI spells it.
        _ = run(.endpointUpdate(endpoint: .id(id), spec: EndpointSpec(groupTag: groupTag ?? "")))
    }

    /// One writer. The command mutates the project, and applying the project is what reaches the
    /// engine — the direct write to the runtime's copy that used to lead this method was the reason
    /// the window appeared to work while `mimic server configure --delay` did not.
    func updateGlobalDelay(delayMs: Int) {
        _ = run(.serverConfigure(port: nil, globalDelayMs: delayMs))
    }

    /// Adds the selected candidates to the open project, through ``ImportCommitter`` — which applies
    /// them with `ProjectCommandExecutor`, so an import is held to exactly the rules an edit is.
    ///
    /// The pipeline itself moved out: it is a transformation of a `MockProject` by a list of
    /// candidates, and it needed a store, a runtime and a live session to reach only because it was a
    /// method here. What is left is the part that genuinely belongs to a session — publishing the
    /// project the commit produced, scheduling the save, and reporting what was refused.
    ///
    /// The signature stays `Void` because this method is handed straight to `ImportView` as its
    /// `([ImportCandidate]) -> Void` commit action, so the reasons go to `lastCommandError` — the
    /// channel `ContentView` already presents.
    func commitImportedCandidates(_ candidates: [ImportCandidate]) {
        let outcome = ImportCommitter(project: currentProject).commit(candidates)

        // Published once, and only if something survived: assigning `currentProject` is what pushes
        // the project to the engine and restarts the autosave debounce, so an import in which every
        // candidate was refused should cost neither. `ImportCommitter` reports that by answering with
        // no project rather than by handing back an unchanged one.
        if var project = outcome.project {
            project.modifiedAt = Date()
            currentProject = project
            projects.scheduleAutosave()
        }

        switch outcome.report {
        // Nothing was selected, so nothing was attempted: a reason the previous command left in
        // `lastCommandError` is still the truth about that command and must not be wiped by a
        // no-op confirmation.
        case .unchanged: break
        case .cleared: lastCommandError = nil
        case let .skipped(message): lastCommandError = message
        }
    }

    // MARK: - Scenarios

    func addScenario(endpointID: UUID, name: String, statusCode: Int = 200) -> Scenario? {
        run(.scenarioCreate(
            endpoint: .id(endpointID),
            name: name,
            spec: ScenarioSpec(statusCode: statusCode)
        ))?.scenario
    }

    func setActiveScenario(endpointID: UUID, scenarioID: UUID) {
        _ = run(.scenarioActivate(endpoint: .id(endpointID), scenario: .id(scenarioID)))
    }

    func duplicateScenario(endpointID: UUID, scenarioID: UUID) -> Scenario? {
        guard let source = currentProject?.endpoints
            .first(where: { $0.id == endpointID })?
            .scenarios
            .first(where: { $0.id == scenarioID })
        else { return nil }

        return run(.scenarioCreate(
            endpoint: .id(endpointID),
            name: "\(source.name) (Copy)",
            spec: ScenarioSpec(
                statusCode: source.statusCode,
                headers: source.headers,
                body: source.body,
                contentType: source.bodyContentType
            )
        ))?.scenario
    }

    func deleteScenario(endpointID: UUID, scenarioID: UUID) {
        _ = run(.scenarioDelete(endpoint: .id(endpointID), scenario: .id(scenarioID)))
    }

    func renameScenario(endpointID: UUID, scenarioID: UUID, name: String) {
        _ = run(.scenarioUpdate(
            endpoint: .id(endpointID),
            scenario: .id(scenarioID),
            spec: ScenarioSpec(name: name)
        ))
    }

    // MARK: - Journeys

    @discardableResult
    func addJourney(name: String) -> Journey? {
        run(.journeyCreate(name: name, spec: nil))?.journey
    }

    @discardableResult
    func addJourney(fromTemplate templateID: String, name: String? = nil) -> Journey? {
        run(.journeyAddTemplate(templateID: templateID, name: name))?.journey
    }

    @discardableResult
    func duplicateJourney(id: UUID) -> Journey? {
        run(.journeyDuplicate(journey: .id(id)))?.journey
    }

    func deleteJourney(id: UUID) {
        _ = run(.journeyDelete(journey: .id(id)))
        if selectedJourneyID == id { selectedJourneyID = journeys.first?.id }
    }

    func updateJourney(id: UUID, spec: JourneySpec) {
        _ = run(.journeyUpdate(journey: .id(id), spec: spec))
    }

    @discardableResult
    func addJourneyStep(journeyID: UUID, spec: JourneyStepSpec, at index: Int? = nil) -> Journey? {
        run(.journeyStepAdd(journey: .id(journeyID), step: spec, atIndex: index))?.journey
    }

    func updateJourneyStep(journeyID: UUID, stepID: UUID, spec: JourneyStepSpec) {
        _ = run(.journeyStepUpdate(journey: .id(journeyID), step: .id(stepID), spec: spec))
    }

    func removeJourneyStep(journeyID: UUID, stepID: UUID) {
        _ = run(.journeyStepRemove(journey: .id(journeyID), step: .id(stepID)))
    }

    /// Appends the steps reproducing a run of requests the server already answered.
    ///
    /// One command rather than one per step: one user action should be one mutation and one save.
    /// Autosaves in quick succession cancel each other, which surfaces as a spurious "Save failed" —
    /// and capturing a session is a dozen of them at once.
    @discardableResult
    func addJourneySteps(journeyID: UUID, capturing logs: [RequestLog]) -> Journey? {
        let steps = JourneyStepSpec.capturing(logs)
        guard !steps.isEmpty else { return nil }
        return run(.journeyStepsAdd(journey: .id(journeyID), steps: steps, atIndex: nil))?.journey
    }

    /// Creates a journey from a run of observed requests — the way a flow usually starts.
    ///
    /// Created *with* its steps in a single command rather than create-then-append, for the same
    /// one-action-one-save reason as ``addJourneySteps(journeyID:capturing:)``.
    @discardableResult
    func addJourney(name: String, capturing logs: [RequestLog]) -> Journey? {
        run(.journeyCreate(
            name: name,
            spec: JourneySpec(steps: JourneyStepSpec.capturing(logs))
        ))?.journey
    }

    /// How many steps a selection would actually produce, for the capture sheet to report before the
    /// user commits. Not `logs.count`: requests a journey already answered are dropped, and a run of
    /// identical polls collapses into one repeating step.
    ///
    /// The rule lives in ``JourneyCapture`` — it is a function of the logs, with no session in it.
    /// This forwards so `WorkspaceView`'s call site is unchanged.
    static func capturedStepCount(_ logs: [RequestLog]) -> Int {
        JourneyCapture.stepCount(logs)
    }

    /// Names a journey captured from a run after the resource its *earliest* call touches — the call
    /// the flow starts with, which is what people name a flow after. See ``JourneyCapture``.
    static func journeyName(capturing logs: [RequestLog]) -> String {
        JourneyCapture.name(capturing: logs)
    }

    /// Names a new journey after the resource the first captured call touches, which is nearly always
    /// what the flow is about. See ``JourneyCapture``.
    static func journeyName(capturing log: RequestLog) -> String {
        JourneyCapture.name(capturing: log)
    }

    func moveJourneyStep(journeyID: UUID, stepID: UUID, to index: Int) {
        _ = run(.journeyStepMove(journey: .id(journeyID), step: .id(stepID), toIndex: index))
    }

    /// Selects the journey that overlays endpoint resolution. Passing `nil` clears it.
    ///
    /// **Activating always begins a clean run, including a re-activation of the journey already
    /// active** — which is the case that makes this more than an assignment. Pushing the project is
    /// *not* what resets the cursor, and this comment claimed for a long time that it was: a push
    /// carrying the same journey with the same steps is how every other edit to the open document
    /// reaches the engine, and one of those must leave a run in progress alone. The two arrive at
    /// `MockRouteStore` looking identical, so the count below is what tells them apart.
    ///
    /// Noted before the mutation, because the push leaves synchronously from `currentProject`'s
    /// `didSet` inside `mutateCurrentProject` — and only when the activation will actually take
    /// effect. An id naming no journey leaves `activeJourneyID` untouched, but it still *pushes*:
    /// `mutateCurrentProject` reassigns `currentProject` whether or not the closure changed
    /// anything, and the `didSet` fires on every assignment. That push is argument-for-argument a
    /// re-push, so it must carry the *un*raised count — raised, it would restart a run nobody
    /// touched, on that push or on the next unrelated edit's.
    ///
    /// Clearing is not an activation and needs no count — a nil journey drops the run state outright.
    func activateJourney(id: UUID?) {
        if let id, projects.currentProject?.journeys.contains(where: { $0.id == id }) == true {
            server.noteJourneyActivation()
        }
        _ = mutateCurrentProject { project in
            guard let id else {
                project.activeJourneyID = nil
                return
            }
            guard project.journeys.contains(where: { $0.id == id }) else { return }
            project.activeJourneyID = id
        }
    }

    func restartActiveJourney() { server.restartJourney() }
    func advanceActiveJourney() { server.advanceJourney() }

    /// Advances the active journey and reports the cursor the engine moved it to.
    ///
    /// ``advanceActiveJourney()`` dispatches and returns, which is right for a menu item and wrong for
    /// a control call: `mimic journey advance` has to answer with the position it produced, and
    /// reading ``activeJourneyStatus`` straight after dispatching reads the mirror from *before* the
    /// advance. Named apart rather than overloaded on `async`, because the synchronous one is handed
    /// to a `Button` and to `JourneyRunControls` as a `() -> Void` action.
    func advanceActiveJourneyReportingStatus() async -> JourneyStatus? {
        await server.advanceJourneyReportingStatus()
    }

    /// Restarts the active journey and reports the cursor the engine reset it to — the restart-shaped
    /// sibling of ``advanceActiveJourneyReportingStatus()``, for the same caller and the same reason.
    func restartActiveJourneyReportingStatus() async -> JourneyStatus? {
        await server.restartJourneyReportingStatus()
    }

    /// The engine's journey cursor, read once the configuration push this session most recently
    /// dispatched has reached it.
    ///
    /// The one caller is `AppControlHost.journeyActivate`, which has to answer with where the run
    /// actually stands. ``activateJourney(id:)`` reaches the engine through `currentProject`'s `didSet`
    /// and therefore from a task, so anything asking the engine straight afterwards is asking before
    /// the push arrived. See ``MockServerRuntime/journeyStatusAfterPendingUpdates()``.
    func journeyStatusAfterPendingMockUpdates() async -> JourneyStatus? {
        await server.journeyStatusAfterPendingUpdates()
    }

    /// The last error a journey edit produced, for surfacing in the UI. Cleared on the next success.
    var lastCommandError: String?

    var isShowingCommandError: Bool {
        get { lastCommandError != nil }
        set { if !newValue { lastCommandError = nil } }
    }

    // MARK: - Projects

    func createProject(name: String, port: Int = 8080) {
        stopServerForProjectChange()
        _ = projects.createProject(name: name, port: port)
    }

    func openProject(id: UUID) {
        stopServerForProjectChange()
        projects.openProject(id: id)
    }

    /// The in-flight ``importProject(_:activate:)`` dispatch — retained, not fire-and-forget.
    ///
    /// `ProjectWorkspace.importProject` joins the write chain synchronously — but only once the
    /// dispatch task has *run*, and between `importProject` returning and that first slice there
    /// is a gap in which the chain has never heard of the import. A shutdown drain started inside
    /// the gap would find nothing to wait for and exit with the document unwritten;
    /// `ControlPlaneCoordinator.startPendingSave` awaits this handle before it drains, which
    /// closes the gap without making the import's reply wait. Dispatches chain on their
    /// predecessor for the same reason the store writes do: two imports back to back must join
    /// the chain in the order they were asked for. `@ObservationIgnored` because a task handle is
    /// shutdown bookkeeping, not something a view renders.
    @ObservationIgnored private(set) var importTask: Task<Void, Never>?

    /// Stores an imported document, and opens it when the caller asked for it.
    ///
    /// Activation waits for the write and goes through ``openProject(id:)`` rather than the
    /// workspace's own: a document that the store refused is not a project to open — opening it would
    /// only send `ProjectWorkspace.openProject` down its missing-project path and strike the entry
    /// from recents — and switching projects has to stop the server the same way every other switch
    /// does.
    ///
    /// A document whose id names the *open* project replaces the session copy too, superseding any
    /// edit still sitting in the autosave debounce — the contract, and the two ways it used to
    /// break, are written on `ProjectWorkspace.importProject`.
    func importProject(_ document: MockProject, activate: Bool) {
        importTask = Task { @MainActor [previousDispatch = importTask, weak self] in
            await previousDispatch?.value
            guard let self else { return }
            let stored = await projects.importProject(document)
            guard stored, activate else { return }
            openProject(id: document.id)
        }
    }

    /// The server serves *the open project*, so it cannot outlive one.
    ///
    /// It used to. Opening or creating another project left the engine bound to the previous
    /// project's port, still reporting "running" — so the window showed a live server for a
    /// configuration you had left, while the project actually in front of you answered nothing. The
    /// status well would read `localhost:8080` next to a project configured for 9000.
    ///
    /// Stopping rather than rebinding, because that is what Xcode does when you switch what you are
    /// working on: the previous run ends, and starting the new one is a decision you make. Silently
    /// moving a live server to a different port would mean a request you sent a moment ago and one
    /// you send now go to different places with nothing on screen having changed.
    private func stopServerForProjectChange() {
        guard currentProject != nil, serverState != .stopped else { return }
        server.stopServer()
    }
    func saveCurrentProject() { projects.saveCurrentProject() }
    func duplicateProject(id: UUID) { projects.duplicateProject(id: id) }
    func deleteProject(id: UUID) {
        if currentProject?.id == id {
            stopServerForProjectChange()
        }
        projects.deleteProject(id: id)
    }
    func closeProject() {
        stopServerForProjectChange()
        projects.closeProject()
    }
    func scheduleAutosave() { projects.scheduleAutosave() }

    // MARK: - Command plumbing

    /// Applies a control command to the open project, persisting and pushing to the engine on success.
    ///
    /// This is the seam that keeps the GUI honest: a menu item and a CLI invocation run the same
    /// Domain code, so a rule can only be implemented once.
    @discardableResult
    private func run(_ command: ControlCommand) -> ControlResult? {
        guard var project = currentProject else { return nil }
        do {
            guard let outcome = try ProjectCommandExecutor.apply(command, to: &project) else { return nil }
            if outcome.didMutate {
                project.modifiedAt = Date()
                currentProject = project
                projects.scheduleAutosave()
            }
            lastCommandError = nil
            return outcome.result
        } catch let error as ControlError {
            lastCommandError = error.message
            return nil
        } catch {
            lastCommandError = error.localizedDescription
            return nil
        }
    }

    private func bindProjectWorkspace() {
        // Every change applies the whole project, configuration included.
        //
        // This used to take the configuration only when the *identity* of the open project changed,
        // behind a `syncConfigurationOnNextProjectChange` flag, and push endpoints alone otherwise.
        // But the configuration is edited in place on the open project — `mimic server configure
        // --delay 500` is a `.serverConfigure` command like any other — so that edit reached the
        // project and stopped there. The engine kept the old delay, `mimic server status` reported
        // the old port, the editor's "Global delay" row showed a number nothing had changed, and
        // `startServer` bound whichever port the runtime happened to be holding. The window and the
        // script disagreed about the same project, which is the one thing this seam exists to
        // prevent — and the headless host, which keeps no second copy, behaved correctly all along.
        projects.onCurrentProjectChanged = { [weak self] project in
            self?.server.applyProject(project)
        }
        server.applyProject(projects.currentProject)
    }

    @discardableResult
    private func mutateCurrentProject(
        autosave: Bool = true,
        _ mutation: (inout MockProject) -> Void
    ) -> Bool {
        let updated = projects.mutateCurrentProject(mutation)
        if updated && autosave {
            projects.scheduleAutosave()
        }
        return updated
    }
}
