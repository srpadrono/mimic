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

    var showNewEndpointSheet = false
    /// The new-project sheet, presented by `ContentView` so one flag serves both the welcome window
    /// and an open workspace — File ▸ New Project has to work from either.
    var showNewProjectSheet = false
    /// A menu or CLI request to switch the sidebar to a given navigator. Consumed by `WorkspaceView`
    /// and reset, because the menu sits above the window that owns the sidebar's state.
    ///
    /// This is how Journeys ▸ Show Journeys arrives too. There used to be a separate `showJourneys`
    /// flag that opened a window; journeys have one home now, so there is one request.
    var navigatorRequest: NavigatorTab?
    /// The journey being edited in the navigator.
    var selectedJourneyID: UUID?
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
    var currentProject: MockProject? {
        get { projects.currentProject }
        set { projects.currentProject = newValue }
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
        panelLayoutStore: PanelLayoutStore = PanelLayoutStore()
    ) {
        #if DEBUG
        Self.instancesCreated += 1
        #endif
        self.server = server
        self.panelLayoutStore = panelLayoutStore
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
            return ProjectStore.open(makeOnDisk: {
                try DatabaseFactory.makeAppDatabaseQueue(
                    environment: [DatabaseFactory.databasePathEnvironmentKey: testDatabaseURL.path]
                )
            })
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

    func updateEndpoint(_ updated: Endpoint) {
        // A whole-value replacement, which the editor produces; the executor's spec API is for
        // partial edits, so this one stays a direct write.
        _ = mutateCurrentProject {
            guard let index = $0.endpoints.firstIndex(where: { $0.id == updated.id }) else { return }
            $0.endpoints[index] = updated
        }
    }

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

    /// Adds the selected candidates to the open project — through the executor, so an import is held
    /// to exactly the rules an edit is.
    ///
    /// This used to build `Scenario` and `Endpoint` inline and append them, which made importing the
    /// one way into a project that validated nothing. `ProjectCommandExecutor` guards every edit and
    /// `ProjectValidator` guards `projectImport`; this went around both, and `SpecImport` does not
    /// validate either — it reports what it read.
    ///
    /// Real captures make that reachable rather than theoretical. A browser writes `"status": 0` into
    /// a HAR for every cancelled, blocked or transport-failed request, and a session's worth of
    /// traffic normally contains several. Stored verbatim, that 0 reached the serving path, where
    /// `VaporConfigurator.clampedStatusCode` answered 200 while the editor showed 0 and flagged the
    /// user's own field as invalid — the request and the window disagreeing about the same mock. A
    /// response header carrying CR or LF went the same way: accepted here, silently dropped when the
    /// response was written, under a comment in `VaporConfigurator` promising that "the validators on
    /// the editing and import paths are where a bad header gets a real error message".
    ///
    /// Refused candidates are reported, never dropped. The signature stays `Void` because this method
    /// is handed straight to `ImportView` as its `([ImportCandidate]) -> Void` commit action, so the
    /// reasons go to `lastCommandError` — the channel `ContentView` already presents.
    func commitImportedCandidates(_ candidates: [ImportCandidate]) {
        let selected = candidates.filter(\.isSelected)
        guard !selected.isEmpty else { return }

        // One copy, mutated through the executor, published once at the end.
        //
        // Routing this through `run(_:)` per command was correct about the rules and wrong about the
        // cost: every mutating `run` assigns `currentProject`, and that `didSet` applies the whole
        // project to the engine and reschedules the autosave debounce. A candidate takes two
        // commands, so a 300-entry HAR — an ordinary size for a real capture — meant six hundred
        // whole-project pushes to the engine actor and six hundred debounce restarts on the main
        // actor, for one confirmation of one sheet. The rules still have exactly one implementation:
        // this calls the same `ProjectCommandExecutor.apply` that `run(_:)` does.
        guard var project = currentProject else {
            lastCommandError = "Skipped all \(selected.count) imported endpoints: no project is open."
            return
        }

        var rejections: [String] = []
        var didMutate = false

        for candidate in selected {
            let route = "\(candidate.method.rawValue) \(candidate.path)"

            // Checked before anything is created, because a candidate takes two commands — the
            // endpoint, then its response — and a bad response caught only by the second would leave
            // an endpoint behind still answering the placeholder 200 `makeEndpoint` gives it: a mock
            // nobody captured, standing in for the one they did. These are the same validators the
            // executor calls, so the rule still has a single implementation; only the moment it runs
            // is different.
            if let reason = Self.importRejection(for: candidate) {
                rejections.append("\(route) — \(reason)")
                continue
            }

            // Taken before the pair and restored if either half fails. Rolling back by value is what
            // the old `endpointDelete` command was reaching for, and it cannot half-succeed: an
            // endpoint created by the first command but left without its captured response is a mock
            // nobody asked for, standing in for the one they did.
            let beforeCandidate = project

            do {
                guard let created = try ProjectCommandExecutor.apply(
                    .endpointCreate(
                        name: candidate.suggestedName,
                        method: candidate.method,
                        path: candidate.path,
                        // The executor reads an empty string as "clear", which is what a candidate
                        // with no group and no GraphQL operation means.
                        spec: EndpointSpec(
                            groupTag: candidate.suggestedGroupTag ?? "",
                            graphqlOperation: candidate.graphqlOperation ?? ""
                        )
                    ),
                    to: &project
                )?.result.endpoint,
                    let scenarioID = created.activeScenarioID
                else {
                    project = beforeCandidate
                    rejections.append("\(route) — the endpoint could not be created")
                    continue
                }

                _ = try ProjectCommandExecutor.apply(
                    .scenarioUpdate(
                        endpoint: .id(created.id),
                        scenario: .id(scenarioID),
                        spec: ScenarioSpec(
                            name: "Imported",
                            statusCode: candidate.statusCode,
                            headers: candidate.responseHeaders,
                            body: candidate.responseBody,
                            contentType: candidate.responseContentType
                        )
                    ),
                    to: &project
                )
                didMutate = true
            } catch let error as ControlError {
                project = beforeCandidate
                rejections.append("\(route) — \(error.message)")
            } catch {
                project = beforeCandidate
                rejections.append("\(route) — \(error.localizedDescription)")
            }
        }

        // Published once, and only if something survived: assigning `currentProject` is what pushes
        // the project to the engine and restarts the autosave debounce, so an import in which every
        // candidate was refused should cost neither.
        if didMutate {
            project.modifiedAt = Date()
            currentProject = project
            projects.scheduleAutosave()
        }

        guard !rejections.isEmpty else {
            lastCommandError = nil
            return
        }
        // Assigned after the loop rather than inside it: every command that succeeds clears
        // `lastCommandError`, so a reason recorded mid-import would be erased by the next candidate
        // that lands — which is the silent drop this whole method exists to stop.
        lastCommandError = """
        Skipped \(rejections.count) of \(selected.count) imported endpoints:

        \(rejections.joined(separator: "\n"))
        """
    }

    /// Why an imported candidate cannot become an endpoint, or `nil` when it can.
    ///
    /// Exactly the three checks `ProjectCommandExecutor` would apply to the two commands
    /// ``commitImportedCandidates(_:)`` runs — path on the create, status and headers on the
    /// response — run early enough that a refusal costs no half-made endpoint.
    private static func importRejection(for candidate: ImportCandidate) -> String? {
        do {
            try EndpointValidator.validatePath(candidate.path)
            try EndpointValidator.validateStatusCode(candidate.statusCode)
            try EndpointValidator.validateHeaders(candidate.responseHeaders)
            return nil
        } catch {
            return error.localizedDescription
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
    static func capturedStepCount(_ logs: [RequestLog]) -> Int {
        JourneyStepSpec.capturing(logs).count
    }

    /// Names a journey captured from a run after the resource its *earliest* call touches — the call
    /// the flow starts with, which is what people name a flow after.
    ///
    /// Chronological, not whichever row happens to be first in the selection: the log draws
    /// newest-first by default, so "the first one handed over" is normally the last thing that
    /// happened.
    static func journeyName(capturing logs: [RequestLog]) -> String {
        let capturable = logs.filter { $0.outcome != .journey }
        guard let first = capturable.min(by: { $0.timestamp < $1.timestamp }) else {
            return "Captured flow"
        }
        return journeyName(capturing: first)
    }

    /// Names a new journey after the resource the first captured call touches, which is nearly always
    /// what the flow is about.
    static func journeyName(capturing log: RequestLog) -> String {
        let path = log.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? log.path
        let resource = path
            .split(separator: "/")
            .map(String.init)
            .last { segment in
                let lower = segment.lowercased()
                let isVersion = lower.hasPrefix("v") && lower.dropFirst().allSatisfy(\.isNumber)
                return lower != "api" && !isVersion && !segment.allSatisfy(\.isNumber)
            }
        guard let resource else { return "Captured flow" }
        // Sentence case, not title case: "Account summary flow" reads better next to a lowercase
        // "flow" than "Account Summary Flow" does.
        let words = resource.replacingOccurrences(of: "-", with: " ")
        return "\(words.prefix(1).uppercased())\(words.dropFirst()) flow"
    }

    func moveJourneyStep(journeyID: UUID, stepID: UUID, to index: Int) {
        _ = run(.journeyStepMove(journey: .id(journeyID), step: .id(stepID), toIndex: index))
    }

    /// Selects the journey that overlays endpoint resolution. Passing `nil` clears it.
    ///
    /// Pushing the project to the engine is what resets the cursor, so activating always begins a
    /// clean run — the same guarantee `mimic journey activate` gives.
    func activateJourney(id: UUID?) {
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

    /// Stores an imported document, and opens it when the caller asked for it.
    ///
    /// Activation waits for the write and goes through ``openProject(id:)`` rather than the
    /// workspace's own: a document that the store refused is not a project to open — opening it would
    /// only send `ProjectWorkspace.openProject` down its missing-project path and strike the entry
    /// from recents — and switching projects has to stop the server the same way every other switch
    /// does.
    func importProject(_ document: MockProject, activate: Bool) {
        Task { @MainActor [weak self] in
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
