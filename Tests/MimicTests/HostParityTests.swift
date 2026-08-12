import Foundation
import Testing
import ControlPlane
import Domain
import MockServerEngine
import Persistence
@testable import AppFeatures

/// The two `ControlHost` conformances, asked the same questions side by side.
///
/// `AppControlHost` maps a command onto the live session behind the window; `MimicControlService`
/// owns a repository and an engine of its own. They are meant to answer identically, and every
/// divergence between them so far was found by *reading* the two files next to each other — never by
/// a test, because until now no test drove both. `Tests/ControlPlaneTests` is thirty-eight tests
/// against the service alone, and the `AppControlHost` cases in `AppStateAndViewTests` are four
/// against the host alone; two green suites prove nothing about whether the two agree.
///
/// What "agree" means here is deliberately narrow, because over-asserting would fail this suite for
/// things that are not defects:
///
/// - **`ok`**, always. A command that succeeds against one instance and fails against the other is a
///   divergence whatever either of them says about it.
/// - **the error `code`**, which is the part a script branches on. Codes come from `ControlError`'s
///   own constructors in Domain, so two hosts reaching the same failure really do produce the same
///   string — a difference there is drift, not wording.
/// - **which result fields are populated**, compared as the JSON keys `ControlCoding` writes. A
///   caller that reads `result.project` is broken by its absence however friendly the message is.
///
/// Prose is asserted in exactly two places: where both hosts build the sentence in the *same* place
/// (``ControlMessages/reset(clearedLogEntries:restartedJourneyName:)``), and where the difference is
/// itself the thing being pinned — see ``contractDifferences`` and the `DIVERGENCE` tests. `ping` and
/// `logClear` are deliberately *not* pinned even though the two hosts agree on them today: those
/// sentences are written out longhand in both files, and a test asserting they match would be
/// asserting a coincidence rather than a contract. They are noted here so the omission reads as a
/// decision rather than an oversight.
@Suite("Host parity", .serialized)
@MainActor
struct HostParityTests {

    // MARK: - Fixtures

    /// One window-hosted session and one headless service, each over its own in-memory store.
    ///
    /// Separate stores, not one shared queue: the window's host writes through `AppState`'s autosave
    /// and the service writes directly, so a single `DatabaseQueue` would have them racing over a
    /// project each believes it owns. What has to match is the state a command *sees*, and that is
    /// arranged by driving the same commands through both.
    private struct ParityHosts {
        let window: AppControlHost
        let headless: MimicControlService
        /// Held because `AppControlHost` holds the session *weakly*, so nothing else here keeps it
        /// alive. Drop this and every command against the window answers "The Mimic session is no
        /// longer available." — a suite that would look like a broken host rather than a freed one.
        let appState: AppState
    }

    private struct ParityResponses {
        let window: ControlResponse
        let headless: ControlResponse
    }

    /// An engine that serves nothing and reports no journey.
    ///
    /// Every command this suite drives is one that needs neither a bound port nor served traffic, and
    /// the window's host reaches the engine only through `MockServerRuntime`. A stub keeps the app
    /// side deterministic and keeps a parity run from opening a socket.
    private actor ParityStubEngine: MockServerEngineProtocol {
        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func start(configuration: ServerConfiguration) async throws {
            // Nothing binds a port here; the runtime only needs the call to return.
        }

        func stop() async throws {}

        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {}
    }

    private func makeHosts() throws -> ParityHosts {
        let headlessQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let headless = MimicControlService(
            repository: GRDBProjectRepository(dbQueue: headlessQueue),
            settings: SettingsStore(dbQueue: headlessQueue),
            engine: MockServerEngine(),
            // The window's host derives its mode from the process environment. Hard-coding
            // `"headless"` here would make `state` disagree about `mode` for a reason that has
            // nothing to do with either host, and the suite would be reporting on its own fixture.
            mode: HeadlessMode.isEnabled ? "headless" : "app"
        )

        let windowQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        // Its own defaults suite, so a run cannot inherit — or overwrite — a real recents list or a
        // real window arrangement. `PanelLayoutStore()` would bind to `.standard` and do exactly that.
        let defaults = try #require(UserDefaults(suiteName: "HostParityTests.\(UUID().uuidString)"))
        let appState = AppState(
            server: MockServerRuntime(engine: ParityStubEngine()),
            projectRepository: GRDBProjectRepository(dbQueue: windowQueue),
            recentProjectsStore: RecentProjectsStore(defaults: defaults),
            panelLayoutStore: PanelLayoutStore(defaults: defaults)
        )

        return ParityHosts(
            window: AppControlHost(appState: appState, repository: appState.repository),
            headless: headless,
            appState: appState
        )
    }

    /// Opens the same project on both hosts, through the command surface rather than around it.
    ///
    /// `projectCreate` is one of the declared contract differences — the window answers optimistically
    /// — but it opens the project synchronously on both sides, which is what the rest of the suite
    /// needs. A seed that failed would make every downstream assertion meaningless, so both replies
    /// are required to carry a result.
    private func seedProject(
        _ hosts: ParityHosts,
        name: String = "Checkout",
        port: Int = 9099
    ) async throws {
        let responses = await run(.projectCreate(name: name, port: port), on: hosts)
        _ = try #require(responses.window.result, "the window's host did not open the seed project")
        _ = try #require(responses.headless.result, "the headless service did not open the seed project")
    }

    // MARK: - Comparison

    private func run(_ command: ControlCommand, on hosts: ParityHosts) async -> ParityResponses {
        ParityResponses(
            window: await hosts.window.execute(command),
            headless: await hosts.headless.execute(command)
        )
    }

    /// Runs `command` against both hosts and requires the answers to agree in the ways that matter.
    @discardableResult
    private func expectParity(
        _ command: ControlCommand,
        on hosts: ParityHosts,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> ParityResponses {
        let responses = await run(command, on: hosts)
        let name = command.kind.rawValue
        // Built into locals first: `#expect`'s comment parameter is a `Comment`, which a string
        // *literal* converts to and a `String` expression does not.
        let windowSays = responses.window.error?.message ?? responses.window.result?.message ?? "—"
        let headlessSays = responses.headless.error?.message ?? responses.headless.result?.message ?? "—"
        let okSummary = "window \(responses.window.ok) (\(windowSays)), "
            + "headless \(responses.headless.ok) (\(headlessSays))"
        let codeSummary = "window \(responses.window.error?.code ?? "none"), "
            + "headless \(responses.headless.error?.code ?? "none")"

        #expect(
            responses.window.ok == responses.headless.ok,
            "\(name) succeeded on one host and failed on the other: \(okSummary)",
            sourceLocation: sourceLocation
        )
        #expect(
            responses.window.error?.code == responses.headless.error?.code,
            "\(name) failed with different codes: \(codeSummary)",
            sourceLocation: sourceLocation
        )

        let windowFields = try Self.populatedFields(responses.window.result)
        let headlessFields = try Self.populatedFields(responses.headless.result)
        #expect(
            windowFields == headlessFields,
            "\(name): window populated \(windowFields.sorted()), headless \(headlessFields.sorted())",
            sourceLocation: sourceLocation
        )

        return responses
    }

    /// The result fields a caller can actually see, taken from the wire rather than from a hand-kept
    /// list of properties.
    ///
    /// `ControlResult`'s synthesized encoder omits `nil` optionals entirely, so the JSON keys *are*
    /// the populated fields — and a field added to `ControlResult` later is compared without anybody
    /// remembering to add it here.
    private static func populatedFields(_ result: ControlResult?) throws -> Set<String> {
        guard let result else { return [] }
        let data = try ControlCoding.encoder().encode(result)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return Set(object.keys)
    }

    // MARK: - Agreement, with nothing open

    /// The state a script meets first: an instance that has been reached but has no project yet.
    @Test(
        "Both hosts answer identically with no project open",
        arguments: [
            ControlCommand.ping,
            .describeCommands,
            .state,
            .projectList,
            .projectExport(project: nil),
            .projectCreate(name: "   ", port: nil),
            .serverStatus,
            .serverStop,
            .serverStart(port: nil),
            .logList(limit: nil, unmatchedOnly: nil),
            .logClear,
            .reset(scope: .all),
            .reset(scope: .journey),
            .endpointList,
            .journeyList,
            .journeyStatus,
            .journeyRestart,
            .journeyAdvance,
            .journeyActivate(journey: nil),
            .projectRename(name: "Renamed"),
            .serverConfigure(port: 9000, globalDelayMs: nil),
        ]
    )
    func hostsAgreeWithNoProjectOpen(command: ControlCommand) async throws {
        let hosts = try makeHosts()
        try await expectParity(command, on: hosts)
    }

    // MARK: - Agreement, with a project open

    /// The same surface once a project exists. The project-scoped entries are here on purpose: they
    /// are answered by `ProjectCommandExecutor` for both hosts, so they are the control group — if one
    /// of these ever disagrees, the seam itself has come apart rather than a host having drifted.
    @Test(
        "Both hosts answer identically with a project open",
        arguments: [
            ControlCommand.state,
            .serverStatus,
            .serverConfigure(port: 9222, globalDelayMs: 125),
            .serverConfigure(port: nil, globalDelayMs: nil),
            .projectRename(name: "Renamed"),
            .projectRename(name: ""),
            .projectExport(project: nil),
            .endpointList,
            .endpointCreate(name: "Login", method: .post, path: "/login", spec: nil),
            .endpointCreate(name: "Bad", method: .get, path: "no-leading-slash", spec: nil),
            .endpointGet(endpoint: .route(.get, "/missing")),
            .endpointDelete(endpoint: .name("nope")),
            .journeyList,
            .journeyTemplateList,
            .journeyAddTemplate(templateID: "payment-retry", name: "Flow"),
            .journeyAddTemplate(templateID: "no-such-template", name: nil),
            .journeyActivate(journey: .name("nope")),
            .journeyActivate(journey: nil),
            .journeyStatus,
            .journeyRestart,
            .journeyAdvance,
            .logList(limit: 5, unmatchedOnly: true),
            .logClear,
            .reset(scope: .all),
            .reset(scope: .logs),
            .reset(scope: .journey),
        ]
    )
    func hostsAgreeWithAProjectOpen(command: ControlCommand) async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)
        try await expectParity(command, on: hosts)
    }

    /// An imported document is the one way into a project that skips the per-field validators, so both
    /// hosts run `ProjectValidator` before anything is stored. They refuse the same document with the
    /// same code — and, because the sentence is built by `ControlError.validation` in Domain rather
    /// than by either host, with the same message.
    @Test("Both hosts refuse an invalid document before storing it")
    func hostsAgreeOnAnInvalidImport() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)

        let broken = MockProject(
            name: "Broken",
            serverConfiguration: ServerConfiguration(port: 70_000, globalDelayMs: 0)
        )
        let responses = try await expectParity(
            .projectImport(project: broken, activate: false),
            on: hosts
        )

        #expect(responses.window.error?.code == "request.invalid")
        #expect(responses.window.error?.message == responses.headless.error?.message)
    }

    /// `reset` is the one reply both hosts build in the same place, so it is the one whose wording is
    /// worth pinning. It reported `Reset all.` from the window and `Reset 12 log entries and journey
    /// "Checkout"` from the service until `ControlMessages` was introduced; this is what stops that
    /// happening again.
    @Test("Reset reports what it cleared, in the same words, from both hosts")
    func resetSaysTheSameThing() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)

        let idle = try await expectParity(.reset(scope: .all), on: hosts)
        #expect(idle.window.result?.message == idle.headless.result?.message)
        #expect(idle.window.result?.message == "Reset 0 log entries.")

        // A scope whose every target reports nothing back is the other half of the sentence.
        let nothing = try await expectParity(.reset(scope: .journey), on: hosts)
        #expect(nothing.window.result?.message == nothing.headless.result?.message)
        #expect(nothing.window.result?.message == "Nothing to reset.")

        try await expectParity(.journeyAddTemplate(templateID: "payment-retry", name: "Flow"), on: hosts)
        try await expectParity(.journeyActivate(journey: .name("Flow")), on: hosts)

        // The window reads the journey it is about to rewind from the session; the service reads the
        // name back off the engine's cursor. Two different routes to the same sentence.
        let running = try await expectParity(.reset(scope: .journey), on: hosts)
        #expect(running.window.result?.message == running.headless.result?.message)
        #expect(running.window.result?.message == "Reset journey \"Flow\".")
    }

    /// A whole script, in order, rather than one command against a fresh instance — because a host
    /// that answers every command correctly in isolation can still lose track of what it has been
    /// asked to do.
    @Test("A scripted flow gets the same answers from both hosts at every step")
    func aScriptedFlowAgreesAtEveryStep() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)

        // The configuration a command writes has to be the configuration the next command reads. The
        // window's host once kept a second copy on the runtime, so `server configure` reached the
        // project and `server status` reported the runtime — this is that bug's parity check.
        try await expectParity(.serverConfigure(port: 9222, globalDelayMs: 125), on: hosts)
        let status = try await expectParity(.serverStatus, on: hosts)
        #expect(status.window.result?.server?.port == 9222)
        #expect(status.window.result?.server?.port == status.headless.result?.server?.port)
        #expect(
            status.window.result?.server?.globalDelayMs
                == status.headless.result?.server?.globalDelayMs
        )

        let created = try await expectParity(
            .endpointCreate(name: "Login", method: .post, path: "/login", spec: nil),
            on: hosts
        )
        #expect(created.window.result?.endpoint?.path == created.headless.result?.endpoint?.path)

        let template = try await expectParity(
            .journeyAddTemplate(templateID: "payment-retry", name: "Flow"),
            on: hosts
        )
        #expect(
            template.window.result?.journey?.steps.count
                == template.headless.result?.journey?.steps.count
        )

        // Activating always begins a clean run on both: the window resets the cursor by applying the
        // project to the engine, the service by pushing its configuration.
        let activated = try await expectParity(.journeyActivate(journey: .name("Flow")), on: hosts)
        #expect(activated.window.result?.journeyStatus?.currentStepIndex == 0)
        #expect(
            activated.window.result?.journeyStatus?.currentStepIndex
                == activated.headless.result?.journeyStatus?.currentStepIndex
        )
        #expect(
            activated.window.result?.journeyStatus?.totalSteps
                == activated.headless.result?.journeyStatus?.totalSteps
        )

        let reported = try await expectParity(.journeyStatus, on: hosts)
        #expect(
            reported.window.result?.journeyStatus?.totalSteps
                == reported.headless.result?.journeyStatus?.totalSteps
        )

        // `state` is the command a caller polls after every optimistic reply, so the counts it carries
        // are the ones a script actually depends on. `appVersion` is left out of the comparison on
        // purpose: the window reads its own bundle and the service is told, which is a difference in
        // what each instance *is*, not in how it answers.
        let state = try await expectParity(.state, on: hosts)
        let windowState = try #require(state.window.result?.state)
        let headlessState = try #require(state.headless.result?.state)
        #expect(windowState.mode == headlessState.mode)
        #expect(windowState.apiVersion == headlessState.apiVersion)
        #expect(windowState.project?.name == headlessState.project?.name)
        #expect(windowState.endpointCount == headlessState.endpointCount)
        #expect(windowState.journeyCount == headlessState.journeyCount)
        #expect(windowState.requestLogCount == headlessState.requestLogCount)
        #expect(windowState.activeJourney?.journeyName == headlessState.activeJourney?.journeyName)
    }

    // MARK: - Declared contract differences

    /// A difference that is contract rather than drift, with the reason it is allowed to exist.
    ///
    /// Written down rather than silently skipped: an exception nobody records is indistinguishable
    /// from a defect nobody noticed, and the point of listing them is that the tests below pin the
    /// current answers — so if one of these ever changes, this suite notices and somebody has to
    /// decide whether the change was intended.
    private struct ContractDifference {
        let kind: CommandKind
        /// What the window's host answers.
        let window: String
        /// What the headless service answers.
        let headless: String
        /// Why the two are allowed to differ.
        let reason: String
    }

    private static let contractDifferences: [ContractDifference] = [
        ContractDifference(
            kind: .projectCreate,
            window: #"ok, "Creating and opening project "X"." and no project field"#,
            headless: #"ok, "Created and opened project "X"." with the project"#,
            reason: """
            The window's store access is asynchronous — autosave, recents and GRDB all sit behind it — \
            and a control call has to answer now, so the command is initiated and the caller confirms \
            with `state`. The service awaits its own repository and can report what it stored.
            """
        ),
        ContractDifference(
            kind: .projectOpen,
            window: #"ok, "Opening project." and no project field"#,
            headless: #"ok, "Opened project "X"." with the project"#,
            reason: "Same asynchronous store access as projectCreate."
        ),
        ContractDifference(
            kind: .projectDuplicate,
            window: #"ok, "Duplicating the project." and no project field"#,
            headless: #"ok, "Duplicated project as "X (Copy)"." with the copy"#,
            reason: "Same asynchronous store access as projectCreate."
        ),
        ContractDifference(
            kind: .projectDelete,
            window: #"ok, "Deleted the project.""#,
            headless: #"ok, "Deleted project "X".""#,
            reason: """
            The window hands the delete to the session and answers; the service awaits the store and \
            has the name it removed. See also the divergence below: because the window never waits, \
            an id that names nothing is accepted rather than refused.
            """
        ),
        ContractDifference(
            kind: .projectImport,
            window: #"ok, "Importing project "X" (n endpoints, n journeys)." with the document"#,
            headless: #"ok, "Imported project "X" (n endpoints, n journeys)." with the document"#,
            reason: """
            Both validate the whole document first and both hand the document back, so only the tense \
            differs: the window's save is a detached task, the service's is awaited.
            """
        ),
        ContractDifference(
            kind: .projectList,
            window: "ok, the session's recents — counts only for the open project",
            headless: "ok, every stored project with accurate counts",
            reason: """
            The window lists what it has already loaded, because the recents list is the app's own \
            listing and is on screen. The service reads the store. Both populate `projects`; what is \
            in them is not the same question.
            """
        ),
        ContractDifference(
            kind: .serverStart,
            window: #"ok, "Starting the server on port N. Poll `mimic server status` to confirm.""#,
            headless: #"ok, "Server running at http://127.0.0.1:N." once it is actually bound"#,
            reason: """
            `MockServerRuntime` starts the engine from a task, so the window can only report the \
            intent. The service awaits `engine.start` and can report the bound address — which is \
            also why this suite never drives it: doing so would open a socket.
            """
        ),
        ContractDifference(
            kind: .serverStop,
            window: #"ok, "Stopping the server.""#,
            headless: #"ok, "Server stopped." — or "Server is not running." when it was not"#,
            reason: "The same asynchronous lifecycle as serverStart, from the other end."
        ),
    ]

    /// The table above can only ever name host-scoped commands.
    ///
    /// A project-scoped command has exactly one implementation — `ProjectCommandExecutor` — so it
    /// cannot legitimately differ between hosts, and listing one here would be a licence to drift
    /// rather than a description of one.
    @Test("Only host-scoped commands are allowed to differ")
    func contractDifferencesNameOnlyHostScopedCommands() {
        for difference in Self.contractDifferences {
            #expect(
                difference.kind.scope == .host,
                "\(difference.kind.rawValue) is project-scoped: one implementation, so it cannot differ"
            )
            // A row describing the same answer twice is a copy-paste, not a difference.
            #expect(
                difference.window != difference.headless,
                "\(difference.kind.rawValue) is listed as a difference but describes one answer twice"
            )
        }
        let kinds = Self.contractDifferences.map(\.kind)
        #expect(Set(kinds).count == kinds.count, "A command is listed twice in contractDifferences.")
    }

    /// The optimistic half of the contract, pinned: the window reports the intent and opens the
    /// project anyway, so the follow-up `state` a caller is told to poll really does confirm it.
    @Test("Project creation is answered optimistically by the window and completely by the service")
    func projectCreateIsOptimisticOnTheWindowHost() async throws {
        let hosts = try makeHosts()
        let responses = await run(.projectCreate(name: "Checkout", port: 9099), on: hosts)

        #expect(responses.window.ok)
        #expect(responses.window.result?.message == "Creating and opening project \"Checkout\".")
        #expect(responses.window.result?.project == nil)

        #expect(responses.headless.ok)
        #expect(responses.headless.result?.message == "Created and opened project \"Checkout\".")
        #expect(responses.headless.result?.project?.name == "Checkout")

        // The half that makes the optimism honest rather than a lie.
        let state = try await expectParity(.state, on: hosts)
        #expect(state.window.result?.state?.project?.name == "Checkout")
        #expect(state.headless.result?.state?.project?.name == "Checkout")
    }

    /// Import differs only in tense — and hands back the same document from both, which is the part a
    /// caller reads.
    @Test("Import differs in tense only")
    func projectImportDiffersInTenseOnly() async throws {
        let hosts = try makeHosts()
        let document = MockProject(name: "Fixture")

        let responses = try await expectParity(
            .projectImport(project: document, activate: false),
            on: hosts
        )

        #expect(responses.window.result?.message?.hasPrefix("Importing project \"Fixture\"") == true)
        #expect(responses.headless.result?.message?.hasPrefix("Imported project \"Fixture\"") == true)
        #expect(responses.window.result?.project?.id == document.id)
        #expect(responses.headless.result?.project?.id == document.id)
    }

    /// Server lifecycle, from both ends, without binding anything.
    ///
    /// Only the window is asked to start: the service would put a real listener on the port, and a
    /// parity suite has no business opening sockets. What the service answers instead is recorded in
    /// ``contractDifferences``.
    @Test("The window reports the intent to start and to stop; the service reports the outcome")
    func serverLifecycleIsOptimisticOnTheWindowHost() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts, port: 9099)

        let started = await hosts.window.execute(.serverStart(port: nil))
        #expect(started.ok)
        #expect(
            started.result?.message
                == "Starting the server on port 9099. Poll `mimic server status` to confirm."
        )

        let stopped = await run(.serverStop, on: hosts)
        #expect(stopped.window.result?.message == "Stopping the server.")
        #expect(stopped.headless.result?.message == "Server is not running.")
    }

    // MARK: - Divergences

    /// DIVERGENCE: `projectExport` takes a project reference, and the window's host ignores it.
    ///
    /// The window answers with whatever is open — so exporting a *different* stored project returns
    /// the wrong document, and exporting one that does not exist returns a document rather than an
    /// error. The service resolves the reference against its store and reports `project.notFound`.
    ///
    /// Pinned, not fixed: `AppControlHost` is not this suite's to change. The `case .projectExport:`
    /// arm binds no associated value, which is why the reference goes missing silently.
    @Test("DIVERGENCE: the window's host ignores the project reference on export")
    func projectExportIgnoresItsReferenceOnTheWindowHost() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts, name: "Checkout")

        let responses = await run(.projectExport(project: .name("Nonexistent")), on: hosts)

        // Window: the reference is dropped and the open project comes back regardless.
        #expect(responses.window.ok)
        #expect(responses.window.result?.project?.name == "Checkout")

        // Service: the reference is resolved, and nothing matches it.
        #expect(responses.headless.ok == false)
        #expect(responses.headless.error?.code == "project.notFound")
    }

    /// DIVERGENCE: a project id that names nothing is refused by the service and accepted by the
    /// window.
    ///
    /// The window resolves a reference by taking `ref.id` if it has one and only otherwise searching
    /// recents, then hands the id to the session and answers immediately — so there is no moment at
    /// which anything checks that a project with that id exists. `projectOpen` and `projectDuplicate`
    /// take the same shape; `projectDelete` stands in for all three here.
    ///
    /// A script that deletes by id therefore gets `ok` from a window and `project.notFound` from a
    /// daemon for the identical command.
    @Test("DIVERGENCE: an unknown project id is accepted by the window and refused by the service")
    func anUnknownProjectIDIsAcceptedByTheWindowHost() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)

        let responses = await run(.projectDelete(project: .id(UUID())), on: hosts)

        #expect(responses.window.ok)
        #expect(responses.window.result?.message == "Deleted the project.")

        #expect(responses.headless.ok == false)
        #expect(responses.headless.error?.code == "project.notFound")

        // A name that matches nothing *is* refused by both, because the window has to search recents
        // for it — so the gap is specifically the reference that skips the lookup.
        let byName = await run(.projectDelete(project: .name("Nonexistent")), on: hosts)
        #expect(byName.window.error?.code == "project.notFound")
        #expect(byName.headless.error?.code == "project.notFound")
    }

    /// DIVERGENCE: `projectClose` names the project it closed from the service and not from the
    /// window, and answers a close with nothing open differently.
    ///
    /// Unlike the rest of the project lifecycle this one is not an artefact of asynchrony —
    /// `AppState.closeProject()` is synchronous and the name is right there in `currentProject`. The
    /// two sentences simply drifted.
    @Test("DIVERGENCE: closing a project is reported differently by each host")
    func projectCloseIsReportedDifferently() async throws {
        let empty = try makeHosts()
        let withNothingOpen = await run(.projectClose, on: empty)
        #expect(withNothingOpen.window.ok)
        #expect(withNothingOpen.headless.ok)
        #expect(withNothingOpen.window.result?.message == "Closed the project.")
        #expect(withNothingOpen.headless.result?.message == "No project was open.")

        let seeded = try makeHosts()
        try await seedProject(seeded, name: "Checkout")
        let withAProjectOpen = await run(.projectClose, on: seeded)
        #expect(withAProjectOpen.window.result?.message == "Closed the project.")
        #expect(withAProjectOpen.headless.result?.message == "Closed project \"Checkout\".")
    }

    /// DIVERGENCE: `journeyAdvance` answers without a `journeyStatus` from the window's host.
    ///
    /// The service asks the engine to advance and reports what the engine hands back. The window asks
    /// the session to advance — which dispatches to the engine and does not report back synchronously
    /// — and then reports `MockServerRuntime`'s *mirror* of the cursor, which the advance it has just
    /// requested has not updated. So the reply carries the cursor from before the command at best, and
    /// no cursor at all when nothing has populated the mirror yet, which is the case a script meets on
    /// its first advance.
    ///
    /// `journeyRestart` beside it does not have this problem: it builds a status from the journey
    /// rather than reading the mirror. Nor does `journeyAdvance` itself when no journey is active —
    /// both hosts refuse it with `journey.noneActive`, which is why the command still appears in the
    /// agreement table above. The gap opens only once there is a cursor to report.
    @Test("DIVERGENCE: advancing a journey reports no status from the window's host")
    func journeyAdvanceOmitsTheStatusOnTheWindowHost() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)
        try await expectParity(.journeyAddTemplate(templateID: "payment-retry", name: "Flow"), on: hosts)
        try await expectParity(.journeyActivate(journey: .name("Flow")), on: hosts)

        let responses = await run(.journeyAdvance, on: hosts)

        #expect(responses.window.ok)
        #expect(responses.headless.ok)
        #expect(responses.window.result?.journeyStatus == nil)
        #expect(responses.headless.result?.journeyStatus != nil)

        // The query beside it agrees, which is what makes the gap specific to the mutation.
        let queried = try await expectParity(.journeyStatus, on: hosts)
        #expect(queried.window.result?.journeyStatus != nil)
    }
}
