import Domain
import Foundation
import MockServerEngine
import Persistence

/// A complete, windowless Mimic: a project store, a mock server, a request log, and the rules for
/// changing any of it.
///
/// The division of labour is the important part. Everything that is a pure function of the open
/// project goes to ``ProjectCommandExecutor`` in Domain, so the CLI and the GUI cannot drift apart.
/// What is left here is the genuinely stateful minority — which project is open, whether the server
/// is running, where the live journey cursor sits, what has been logged — and the persistence and
/// engine plumbing that keeps those three in agreement after every mutation.
public actor MimicControlService: ControlHost {

    public static let maxRequestLogEntries = 1_000

    private let repository: any ProjectRepository
    private let settings: SettingsStore
    private let engine: MockServerEngine
    private let mode: String
    private let appVersion: String?

    private var openProject: MockProject?
    private var requestLogs: [RequestLog] = []
    private var serverState: ServerState = .stopped
    private var logDrain: Task<Void, Never>?

    /// Set for the whole of a `serverStart` or `serverStop`, and read before either suspends.
    ///
    /// Being an actor makes a *statement* atomic, not a sequence of them: `if await engine.isRunning`
    /// is a question asked across a suspension, and the actor admits the next command while the
    /// answer is in flight. Two `serverStart`s arriving together therefore both hear "no", both fall
    /// through, and the second binds — or fails to bind — a port the first has already taken. This
    /// flag is the part of the decision that is a plain read of this actor's own state, so it is
    /// settled before anything can interleave.
    private var isChangingServerState = false

    public init(
        repository: any ProjectRepository,
        settings: SettingsStore,
        engine: MockServerEngine = MockServerEngine(),
        mode: String = "headless",
        appVersion: String? = nil
    ) {
        self.repository = repository
        self.settings = settings
        self.engine = engine
        self.mode = mode
        self.appVersion = appVersion
    }

    /// Starts draining the engine's log stream and reopens the project this instance had open.
    ///
    /// Separate from `init` because both steps are async and because a caller may want a service that
    /// deliberately starts empty (tests do).
    public func start(restoreOpenProject: Bool = true) async {
        if logDrain == nil {
            let stream = engine.logStream
            logDrain = Task { [weak self] in
                for await entry in stream {
                    await self?.appendLog(entry)
                }
            }
        }

        guard restoreOpenProject, openProject == nil else { return }
        if let id = try? await settings.uuid(.openProjectID),
           let project = try? await repository.load(id: id) {
            openProject = project
            await pushConfigurationToEngine()
        }
    }

    public func shutdown() async {
        // The drain task is deliberately left running.
        //
        // Cancelling it would not just end the loop: `AsyncStream`'s iterator finishes the *stream*
        // when the awaiting task is cancelled, and `engine.logStream` is one stream shared for the
        // engine's whole lifetime — the engine says so twice, and does not finish it on `stop` so a
        // stop/start cycle keeps reaching the same consumer. Cancelling here finished it anyway, so a
        // `shutdown()` followed by `start()` produced a service that served traffic and recorded none
        // of it, with nothing to see in `mimic log list`.
        //
        // `logDrain` also stays set, so a later `start()` does not attach a second consumer to a
        // single-consumer stream and split the log between them. The task holds `self` weakly and
        // ends on its own when the engine deallocates and its continuation finishes.
        if await engine.isRunning {
            try? await engine.stop()
        }
        serverState = .stopped
    }

    /// The port the mock server would use, for callers that need it before starting.
    public func configuredMockPort() -> Int {
        openProject?.serverConfiguration.port ?? ServerConfiguration.default.port
    }

    // MARK: - Command execution

    public func execute(_ command: ControlCommand) async -> ControlResponse {
        do {
            return .success(try await run(command))
        } catch let error as ControlError {
            return .failure(error)
        } catch let error as PersistenceError {
            return .failure(.persistenceFailure(error))
        } catch {
            return .failure(.internalFailure(error.localizedDescription))
        }
    }

    private func run(_ command: ControlCommand) async throws -> ControlResult {
        // Project-scoped commands are the large majority and are handled by pure Domain code. Only
        // what genuinely needs this actor's state falls through to the switch below.
        if var project = openProject,
           let outcome = try ProjectCommandExecutor.apply(command, to: &project) {
            if outcome.didMutate {
                project.modifiedAt = Date()
                // Persist first, commit to memory second — the rule `startServer` states below, on
                // the path every project-scoped command takes.
                //
                // The other order published a change the store does not have: `save` throws — a
                // locked database, a full disk — the command reports the failure, and `openProject`
                // is already carrying the edit. `state` and `project export` then answer from it,
                // the next mutation saves it as though it had landed, and `projectSummaries`' "this
                // service saves before it answers, so the stored row is never behind the session" is
                // false in exactly the case that matters.
                //
                // What it costs, stated plainly because it is a real regression on the success path:
                // the read at the top of this method and the commit here are no longer one
                // uninterrupted actor region. A second mutating command admitted during this save
                // reads the project as it was rather than as this command left it, applies its own
                // edit and saves that — so the first command's edit is lost from the store, and
                // whichever task resumes last decides memory.
                //
                // `startServer` is **not** the precedent for this, and an earlier draft of this
                // comment claimed it was. That method guards its own window with
                // `isChangingServerState` and refuses a concurrent server command outright; this
                // path is every project-scoped mutation and has no such guard. The trade is
                // deliberate anyway: the old order was wrong on *every* failed write, while this is
                // wrong only when two mutating commands overlap. Closing it properly means either
                // serialising this region the way `startServer` serialises its own, or re-reading
                // `openProject` after the save and re-applying the command — neither of which is
                // free, and neither of which is worth doing before this host is reachable at all
                // (see "Two hosts, one of them shipped" in AGENTS.md).
                try await repository.save(project)
                openProject = project
                await pushConfigurationToEngine()
            }
            return outcome.result
        }

        // Project-scoped, and nothing is open.
        //
        // `ProjectCommandExecutor` would have handled every one of these; it declined only because
        // there is no project to apply them to, and saying so is far more useful than "unsupported".
        // This used to be a twenty-six-case list at the bottom of the switch below, mirrored case for
        // case by `AppControlHost` and complemented by the executor's own twenty-one — one fact
        // written three times and kept in agreement by hand. `CommandKind.scope` is that fact now,
        // and its switch carries no `default`, so a command added later still cannot compile until
        // somebody decides which side of the line it falls on. That was the whole point of naming
        // twenty-six cases here, and it survives the collapse.
        guard command.kind.scope == .host else { throw ControlError.noProjectOpen }

        switch command {

        // MARK: Discovery

        case .ping:
            return .init(message: ControlMessages.ping(mode: mode, pid: currentPID))

        case .describeCommands:
            return .init(commands: CommandCatalog.descriptors)

        case .state:
            return .init(state: await makeState())

        case let .reset(scope):
            return try await reset(scope: scope)

        // MARK: Projects

        case .projectList:
            return .init(projects: try await projectSummaries())

        case let .projectCreate(name, port):
            guard let trimmed = name.nilIfEmpty else { throw ControlError.emptyProjectName }
            if let port { try validatePort(port) }
            let project = MockProject(
                name: trimmed,
                serverConfiguration: ServerConfiguration(
                    port: port ?? ServerConfiguration.default.port,
                    globalDelayMs: 0
                )
            )
            try await repository.save(project)
            try await open(project)
            return .init(message: "Created and opened project \"\(project.name)\".", project: project)

        case let .projectOpen(ref):
            let project = try await resolveStoredProject(ref)
            try await open(project)
            return .init(message: "Opened project \"\(project.name)\".", project: project)

        case .projectClose:
            let name = openProject?.name
            openProject = nil
            try await settings.set(.openProjectID, to: UUID?.none)
            await pushConfigurationToEngine()
            return .message(name.map { "Closed project \"\($0)\"." } ?? "No project was open.")

        case let .projectDelete(ref):
            let project = try await resolveStoredProject(ref)
            try await repository.delete(id: project.id)
            if openProject?.id == project.id {
                openProject = nil
                try await settings.set(.openProjectID, to: UUID?.none)
                await pushConfigurationToEngine()
            }
            return .message("Deleted project \"\(project.name)\".")

        case let .projectDuplicate(ref):
            let source = try await resolveStoredProject(ref)
            // Every child id reminted. Carrying the source's meant the insert collided with rows the
            // original still owns, and the whole write rolled back — `mimic project duplicate`
            // reported a failure it could not explain, and against the window's host reported success
            // while creating nothing.
            let copy = source.duplicated(name: "\(source.name) (Copy)")
            try await repository.save(copy)
            return .init(message: "Duplicated project as \"\(copy.name)\".", project: copy)

        case let .projectExport(ref):
            if let ref {
                return .init(project: try await resolveStoredProject(ref))
            }
            return .init(project: try requireOpenProject())

        case let .projectImport(document, activate):
            // Validated before it is stored, because an import is the one way into a project that does
            // not pass through the per-field validators the editing commands use. Skipping it let a
            // document carry a status code or header that the app itself would never accept — and that
            // the serving path then had to deal with.
            do {
                try ProjectValidator.validate(document)
            } catch {
                throw ControlError.validation(error)
            }
            // The document's own id is kept, which makes importing a fixture idempotent: a CI job can
            // re-import the same file every run and update in place instead of piling up copies.
            try await repository.save(document)
            if activate {
                try await open(document)
            }
            // Past tense, and that is the whole of the declared difference from the window: the save
            // above was awaited, so this reports what is stored rather than what was accepted.
            return .init(
                message: ControlMessages.projectImported(
                    name: document.name,
                    endpointCount: document.endpoints.count,
                    journeyCount: document.journeys.count
                ),
                project: document
            )

        // MARK: Server

        case let .serverStart(port):
            return try await startServer(port: port)

        case .serverStop:
            return try await stopServer()

        case .serverStatus:
            return .init(server: makeServerStatus())

        // MARK: Journeys — runtime

        case let .journeyActivate(ref):
            return try await activateJourney(ref)

        case .journeyRestart:
            _ = try requireOpenProject()
            guard let status = await engine.restartJourney() else { throw ControlError.noActiveJourney }
            return .init(
                message: ControlMessages.journeyRestarted(name: status.journeyName),
                journeyStatus: status
            )

        case .journeyAdvance:
            _ = try requireOpenProject()
            guard let status = await engine.advanceJourney() else { throw ControlError.noActiveJourney }
            let position = status.currentStepIndex.map(String.init) ?? "complete"
            return .init(message: "Advanced journey to step \(position).", journeyStatus: status)

        case .journeyStatus:
            _ = try requireOpenProject()
            guard let status = await journeyStatus() else { throw ControlError.noActiveJourney }
            return .init(journeyStatus: status)

        // MARK: Logs

        case let .logList(limit, unmatchedOnly):
            // Filter, trim and redaction all live in `HostReport` — including the order they are
            // applied in and the redaction itself, which is the one part of this command that must
            // not be left to two hosts to remember.
            return .init(
                logs: HostReport.requestLog(
                    from: requestLogs,
                    limit: limit,
                    unmatchedOnly: unmatchedOnly
                )
            )

        case .logClear:
            let count = requestLogs.count
            requestLogs = []
            return .message(ControlMessages.logCleared(count: count))

        // MARK: Declared host-scoped, not implemented above
        //
        // Unreachable while `CommandKind.scope` and this switch agree, and the compiler cannot
        // check that they do: the guard above narrows by `CommandKind` while the switch is over
        // `ControlCommand`. Naming the real problem beats falling through to `noProjectOpen`, which
        // would tell the caller to open a project they already have open — the misdirection the old
        // twenty-six-case list existed to prevent.
        default:
            throw ControlError.internalFailure(
                "\(command.kind.rawValue) is host-scoped but this service does not implement it."
            )
        }
    }

    // MARK: - Server lifecycle

    private func startServer(port: Int?) async throws -> ControlResult {
        var project = try requireOpenProject()

        // Everything from here to the `defer` runs without a suspension, so a second `serverStart`
        // cannot reach the engine while this one is still deciding.
        guard !isChangingServerState else { throw ControlError.serverBusy }
        if case let .running(runningPort) = serverState, port == nil || port == runningPort {
            // Answered from this actor's own state rather than from `await engine.isRunning`, which
            // is the check that could not be trusted. Starting twice stays benign — a script that
            // ensures the server is up should not have to ask first.
            return .init(
                message: ControlMessages.serverAlreadyRunning(port: runningPort),
                server: makeServerStatus()
            )
        }
        isChangingServerState = true
        defer { isChangingServerState = false }

        if let port {
            try validatePort(port)
            project.serverConfiguration.port = port
            project.modifiedAt = Date()
            // Persist first, commit to memory second.
            //
            // The other order published a port the store does not have: `save` throws — a locked
            // database, a full disk — and `openProject` was already carrying the new number, so
            // `mimic server status` reported it, the next `pushConfigurationToEngine` served on it,
            // and reopening the project produced the old one. A failed write should leave nothing
            // behind, which means the in-memory copy waits for it.
            try await repository.save(project)
            openProject = project
        }

        // `engine.isRunning` is still worth asking, but only as a backstop now: the flag above is
        // what serialises two callers, and this catches a state the service and the engine could
        // only reach by disagreeing. `serverState` is deliberately not written here — it holds the
        // port that is actually bound, and this branch knows only that *something* is.
        if await engine.isRunning {
            return .init(
                message: ControlMessages.serverAlreadyRunning(port: project.serverConfiguration.port),
                server: makeServerStatus()
            )
        }

        await pushConfigurationToEngine()
        do {
            try await engine.start(configuration: project.serverConfiguration)
            serverState = .running(port: project.serverConfiguration.port)
        // Both codes come from the factories in Domain rather than being spelled out here. They were
        // written inline in these three arms while `AppControlHost` — the host every `mimic`
        // invocation actually reaches — could not report a start failure at all, so "both hosts
        // answer the same" was a claim with only one side of it implemented. Now that the shipped
        // host records the failure too, the two sentences have to be one sentence, and the cheapest
        // way to keep that true is for there to be one of them.
        } catch let error as MockServerError {
            serverState = .error(error.localizedDescription)
            if case let .portInUse(port) = error {
                throw ControlError.serverPortInUse(port: port)
            }
            throw ControlError.serverStartFailed(error.localizedDescription)
        } catch {
            serverState = .error(error.localizedDescription)
            throw ControlError.serverStartFailed(error.localizedDescription)
        }

        // The address comes from the same builder the status report uses, so the sentence and the
        // `baseURL` field beside it cannot name two different places.
        let address = HostReport.loopbackBaseURL(port: project.serverConfiguration.port)
        return .init(message: "Server running at \(address).", server: makeServerStatus())
    }

    private func stopServer() async throws -> ControlResult {
        // The same flag as `startServer`, and it has to be the same one: a stop overlapping a start
        // is the pair that leaves a listener nobody owns, because `engine.stop` clears the engine's
        // own `app` before it awaits the shutdown.
        guard !isChangingServerState else { throw ControlError.serverBusy }
        isChangingServerState = true
        defer { isChangingServerState = false }

        guard await engine.isRunning else {
            serverState = .stopped
            return .init(message: ControlMessages.serverNotRunning, server: makeServerStatus())
        }
        try? await engine.stop()
        serverState = .stopped
        return .init(message: "Server stopped.", server: makeServerStatus())
    }

    // `ControlError.serverBusy` used to be declared here, and again in `AppControlHost`, with a
    // comment in the second promising it matched this one word for word. It lives in Domain now, so
    // the promise is the declaration.

    // MARK: - Journeys

    private func activateJourney(_ ref: JourneyRef?) async throws -> ControlResult {
        var project = try requireOpenProject()

        guard let ref else {
            project.activeJourneyID = nil
            project.modifiedAt = Date()
            // Persist first, commit to memory second — same rule as the executor path above and as
            // `startServer`. A refused write here left the session reporting no active journey while
            // the store still held one, so reopening the project brought it back.
            try await repository.save(project)
            openProject = project
            await pushConfigurationToEngine()
            return .message(ControlMessages.journeyCleared)
        }

        guard let journey = project.journey(matching: ref) else {
            throw ControlError.journeyNotFound(ref)
        }
        project.activeJourneyID = journey.id
        project.modifiedAt = Date()
        // Persist first, commit to memory second, as above: a refused write used to leave the
        // journey active in this session and inactive in the store, so `journey status` reported a
        // run the next `project open` knew nothing about.
        try await repository.save(project)
        openProject = project
        // Counted before the push, and only here — the write above may throw, and an activation that
        // never reached the store must not be the one that restarts a run.
        //
        // This comment used to say "pushing the configuration is what resets the cursor: the engine
        // sees a different journey and starts a fresh run, so activating is always a clean start."
        // The first half was true and the conclusion did not follow: re-activating the journey that
        // is already active pushes the *same* journey, which is indistinguishable from the push any
        // other edit causes, and the engine rightly left the run alone. The count is what separates
        // them. See ``MockRouteStore/update(endpoints:globalDelayMs:journey:activationEpoch:)``.
        journeyActivationEpoch += 1
        await pushConfigurationToEngine()

        return .init(
            message: ControlMessages.journeyActivated(
                name: journey.name,
                stepCount: journey.steps.count
            ),
            journey: journey,
            journeyStatus: await journeyStatus()
        )
    }

    private func journeyStatus() async -> JourneyStatus? {
        guard let journey = openProject?.activeJourney else { return nil }
        // While the server is running the engine owns the live cursor. When it is not, report the
        // journey as not yet started rather than inventing progress.
        if let live = await engine.journeyStatus(), live.journeyID == journey.id {
            return live
        }
        return JourneyStatus.make(journey: journey, state: nil)
    }

    private func reset(scope: ResetScope) async throws -> ControlResult {
        var clearedLogEntries: Int?
        if scope == .logs || scope == .all {
            clearedLogEntries = requestLogs.count
            requestLogs = []
        }

        var restartedJourneyName: String?
        if scope == .journey || scope == .all, let status = await engine.restartJourney() {
            restartedJourneyName = status.journeyName
        }

        return .init(
            message: ControlMessages.reset(
                clearedLogEntries: clearedLogEntries,
                restartedJourneyName: restartedJourneyName
            ),
            state: await makeState()
        )
    }

    // MARK: - State

    private func makeState() async -> ControlState {
        // The awaited value is resolved first, and everything else read from locals afterwards.
        //
        // Written inline among the other arguments, this suspended the actor half way through
        // building one snapshot: arguments evaluate left to right, so `project` and the two counts
        // came from before the hop and `requestLogCount` from after it. A `.logClear` or a
        // `.projectClose` arriving in that window produced a single `state` reply describing two
        // different instants — the hardest kind of wrong answer to reproduce.
        let journey = await journeyStatus()
        let project = openProject
        // Shaping — the summary and the two counts derived from `project` — is `HostReport`'s, so it
        // cannot differ from the window's. What is left here is what this instance alone knows.
        return HostReport.state(
            appVersion: appVersion,
            mode: mode,
            pid: currentPID,
            server: makeServerStatus(),
            project: project,
            activeJourney: journey,
            requestLogCount: requestLogs.count
        )
    }

    /// This service's server state, in the shape the wire uses.
    ///
    /// Only the two values are this actor's to know: with no project open there is no configured
    /// port, so the report falls back to the default rather than inventing one. Everything after
    /// that — the state string, whether a `baseURL` is present, what it says — is
    /// ``HostReport/serverStatus(state:configuredPort:globalDelayMs:)``, shared with the window,
    /// which is where the copy of this switch used to live.
    private func makeServerStatus() -> ServerStatusReport {
        HostReport.serverStatus(
            state: serverState,
            configuredPort: openProject?.serverConfiguration.port ?? ServerConfiguration.default.port,
            globalDelayMs: openProject?.serverConfiguration.globalDelayMs ?? 0
        )
    }

    private func projectSummaries() async throws -> [ProjectSummary] {
        let projects = try await repository.allProjects()
        // `allProjects` returns stubs without endpoints or journeys; the store fills in the counts.
        let counts = (try? await repository.projectCounts()) ?? [:]
        // No open-project overlay: this service saves before it answers, so the stored row is never
        // behind the session the way the window's can be mid-autosave.
        return HostReport.projectSummaries(of: projects, counts: counts)
    }

    // MARK: - Helpers

    private var currentPID: Int { Int(ProcessInfo.processInfo.processIdentifier) }

    private func requireOpenProject() throws -> MockProject {
        guard let openProject else { throw ControlError.noProjectOpen }
        return openProject
    }

    private func resolveStoredProject(_ ref: ProjectRef) async throws -> MockProject {
        if let id = ref.id {
            do {
                return try await repository.load(id: id)
            } catch PersistenceError.projectNotFound {
                throw ControlError.projectNotFound(ref)
            }
            // Everything else — a locked database, an I/O error, a row that will not decode — reaches
            // `execute`, which has a `PersistenceError` branch and an internal-failure fallback that
            // name the real problem. Catching `any Error` here reported all of them as
            // `project.notFound`, so a database Mimic could not open was indistinguishable from a
            // project that had genuinely been deleted, and "my projects vanished" had no diagnosis.
        }
        // Name resolution — the trim, the fold, the first-match rule, and which failure each dead end
        // produces — is `MockProject.requireNamed`, shared with the window's host.
        //
        // The store is read before the reference is checked, which is a change of *order* from the
        // hand-written version this replaced: a `ProjectRef` carrying neither id nor name used to be
        // refused with `request.invalid` before `allProjects()` was called. With a store that
        // answers, the reply is identical either way; with a store that cannot, that reference now
        // reports the store's failure instead. That is the order `AppControlHost` already used, and
        // one order is the point.
        let all = try await repository.allProjects()
        let match = try MockProject.requireNamed(ref, in: all)
        // `allProjects` returns stubs; load the full project so callers get endpoints and journeys.
        return try await repository.load(id: match.id)
    }

    private func open(_ project: MockProject) async throws {
        openProject = project
        try await settings.set(.openProjectID, to: project.id)
        await pushConfigurationToEngine()
    }

    /// Mirrors the open project onto the engine after every mutation, so what the server answers and
    /// what the store holds can never disagree.
    /// How many journey activations this service has performed, carried on every push.
    ///
    /// The same count `MockServerRuntime` keeps, for the same reason: activating the journey that is
    /// already active sends the engine the same endpoints and the same journey as any other mutation
    /// of the open document, and only one of those may restart a run. Kept here rather than derived,
    /// because there is nothing in the pushed arguments to derive it from.
    ///
    /// Incremented by ``activateJourney(_:)`` alone — every other caller of
    /// ``pushConfigurationToEngine()`` is an edit, and an edit that leaves the journey and its steps
    /// untouched must leave a run in progress alone.
    private var journeyActivationEpoch = 0

    private func pushConfigurationToEngine() async {
        await engine.updateConfiguration(
            endpoints: openProject?.endpoints ?? [],
            globalDelayMs: openProject?.serverConfiguration.globalDelayMs ?? 0,
            journey: openProject?.activeJourney,
            activationEpoch: journeyActivationEpoch
        )
    }

    private func validatePort(_ port: Int) throws {
        do {
            try EndpointValidator.validatePort(port)
        } catch {
            throw ControlError.validation(error)
        }
    }

    /// Internal rather than private so a test can seed the log without standing up an engine and
    /// racing its async drain. Not `public`: nothing outside the module has business writing here.
    func appendLog(_ entry: RequestLog) {
        requestLogs.append(entry)
        if requestLogs.count > Self.maxRequestLogEntries {
            requestLogs.removeFirst(requestLogs.count - Self.maxRequestLogEntries)
        }
    }
}
