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
        logDrain?.cancel()
        logDrain = nil
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
            return .failure(ControlError(code: "persistence.failure", message: error.localizedDescription))
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
                openProject = project
                try await repository.save(project)
                await pushConfigurationToEngine()
            }
            return outcome.result
        }

        switch command {

        // MARK: Discovery

        case .ping:
            return .init(message: "Mimic control plane \(ControlAPI.version) (\(mode), pid \(currentPID)).")

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
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ControlError.invalid("Project name must not be empty.") }
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
            let copy = MockProject(
                name: "\(source.name) (Copy)",
                serverConfiguration: source.serverConfiguration,
                endpoints: source.endpoints,
                journeys: source.journeys,
                activeJourneyID: source.activeJourneyID
            )
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
            return .init(
                message: "Imported project \"\(document.name)\" "
                    + "(\(document.endpoints.count) endpoints, \(document.journeys.count) journeys).",
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
            return .init(message: "Restarted journey \"\(status.journeyName)\".", journeyStatus: status)

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

        case let .logList(limit, unmatchedOnly, journeyOnly):
            // Filtering before the limit is the useful order: "the last 20 requests I have no mock
            // for", not "whichever of the last 20 happened to be unmatched".
            //
            // `RequestLogFilter`, shared with the window and with `AppControlHost`. This was the
            // *third* implementation of the same predicate — headless, in-app, and in the drawer —
            // which meant `mimic log list --unmatched` against a daemon and the same command against
            // a running window were two separate answers to one question.
            var entries = RequestLogFilter(
                unmatchedOnly: unmatchedOnly == true,
                journeyOnly: journeyOnly == true
            ).apply(to: requestLogs)
            if let limit { entries = Array(entries.suffix(max(0, limit))) }
            // Redacted on the way out: these are the app-under-test's real credentials, and the log is
            // the one command that hands captured traffic to a caller. See `redactingCredentials()`.
            return .init(logs: entries.map { $0.redactingCredentials() })

        case .endpointCreateFromLog:
            // Deliberately unsupported here. This service answers for a *headless* run, where the
            // request log exists but the window's `AppState` does not — and resolving an entry id
            // needs the same log the host holds. `AppControlHost` implements it; a daemon caller
            // gets a clear refusal rather than a silently different answer.
            throw ControlError(
                code: "log.entryUnavailable",
                message: "create-from-log needs a running window. In a headless run, create the endpoint directly with `mimic endpoint create <METHOD> <PATH>`."
            )

        case .logClear:
            let count = requestLogs.count
            requestLogs = []
            return .message("Cleared \(count) request log \(count == 1 ? "entry" : "entries").")

        // MARK: Project-scoped, but no project is open

        default:
            // Reaching here means `ProjectCommandExecutor` would have handled the command — it only
            // declined because nothing is open. Saying so is far more useful than "unsupported".
            throw ControlError.noProjectOpen
        }
    }

    // MARK: - Server lifecycle

    private func startServer(port: Int?) async throws -> ControlResult {
        var project = try requireOpenProject()

        if let port {
            try validatePort(port)
            project.serverConfiguration.port = port
            project.modifiedAt = Date()
            openProject = project
            try await repository.save(project)
        }

        if await engine.isRunning {
            return .init(
                message: "Server already running on port \(project.serverConfiguration.port).",
                server: makeServerStatus()
            )
        }

        await pushConfigurationToEngine()
        do {
            try await engine.start(configuration: project.serverConfiguration)
            serverState = .running(port: project.serverConfiguration.port)
        } catch let error as MockServerError {
            serverState = .error(error.localizedDescription)
            if case let .portInUse(port) = error {
                throw ControlError(
                    code: "server.portInUse",
                    message: "Port \(port) is already in use. Choose another with `--port`.",
                    details: ["port": String(port)]
                )
            }
            throw ControlError(code: "server.startFailed", message: error.localizedDescription)
        } catch {
            serverState = .error(error.localizedDescription)
            throw ControlError(code: "server.startFailed", message: error.localizedDescription)
        }

        return .init(
            message: "Server running at http://127.0.0.1:\(project.serverConfiguration.port).",
            server: makeServerStatus()
        )
    }

    private func stopServer() async throws -> ControlResult {
        guard await engine.isRunning else {
            serverState = .stopped
            return .init(message: "Server is not running.", server: makeServerStatus())
        }
        try? await engine.stop()
        serverState = .stopped
        return .init(message: "Server stopped.", server: makeServerStatus())
    }

    // MARK: - Journeys

    private func activateJourney(_ ref: JourneyRef?) async throws -> ControlResult {
        var project = try requireOpenProject()

        guard let ref else {
            project.activeJourneyID = nil
            project.modifiedAt = Date()
            openProject = project
            try await repository.save(project)
            await pushConfigurationToEngine()
            return .message("Cleared the active journey; endpoints now answer directly.")
        }

        guard let journey = project.journey(matching: ref) else {
            throw ControlError.journeyNotFound(ref)
        }
        project.activeJourneyID = journey.id
        project.modifiedAt = Date()
        openProject = project
        try await repository.save(project)
        // Pushing the configuration is what resets the cursor: the engine sees a different journey
        // and starts a fresh run, so activating is always a clean start.
        await pushConfigurationToEngine()

        return .init(
            message: "Activated journey \"\(journey.name)\" (\(journey.steps.count) steps).",
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
        var cleared: [String] = []

        if scope == .logs || scope == .all {
            cleared.append("\(requestLogs.count) log entries")
            requestLogs = []
        }
        if scope == .journey || scope == .all {
            if let status = await engine.restartJourney() {
                cleared.append("journey \"\(status.journeyName)\"")
            }
        }

        return .init(
            message: cleared.isEmpty ? "Nothing to reset." : "Reset \(cleared.joined(separator: " and ")).",
            state: await makeState()
        )
    }

    // MARK: - State

    private func makeState() async -> ControlState {
        ControlState(
            appVersion: appVersion,
            mode: mode,
            pid: currentPID,
            server: makeServerStatus(),
            project: openProject.map(ProjectSummary.init),
            endpointCount: openProject?.endpoints.count ?? 0,
            journeyCount: openProject?.journeys.count ?? 0,
            activeJourney: await journeyStatus(),
            requestLogCount: requestLogs.count
        )
    }

    private func makeServerStatus() -> ServerStatusReport {
        let port = openProject?.serverConfiguration.port ?? ServerConfiguration.default.port
        let delay = openProject?.serverConfiguration.globalDelayMs ?? 0

        switch serverState {
        case .running(let runningPort):
            return ServerStatusReport(
                state: "running",
                port: runningPort,
                baseURL: "http://127.0.0.1:\(runningPort)",
                globalDelayMs: delay
            )
        case .stopped:
            return ServerStatusReport(state: "stopped", port: port, baseURL: nil, globalDelayMs: delay)
        case .starting:
            return ServerStatusReport(state: "starting", port: port, baseURL: nil, globalDelayMs: delay)
        case .stopping:
            return ServerStatusReport(state: "stopping", port: port, baseURL: nil, globalDelayMs: delay)
        case let .error(message):
            return ServerStatusReport(
                state: "error",
                port: port,
                baseURL: nil,
                globalDelayMs: delay,
                message: message
            )
        }
    }

    private func projectSummaries() async throws -> [ProjectSummary] {
        let projects = try await repository.allProjects()
        // `allProjects` returns stubs without endpoints or journeys; the store fills in the counts.
        let counts = (try? await repository.projectCounts()) ?? [:]

        return projects.map { project in
            var summary = ProjectSummary(project)
            if let count = counts[project.id] {
                summary.endpointCount = count.endpoints
                summary.journeyCount = count.journeys
            }
            return summary
        }
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
            } catch {
                throw ControlError.projectNotFound(ref)
            }
        }
        guard let name = ref.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw ControlError.invalid("Provide a project id or name.")
        }
        let key = name.lowercased()
        let all = try await repository.allProjects()
        guard let match = all.first(where: { $0.name.lowercased() == key }) else {
            throw ControlError.projectNotFound(ref)
        }
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
    private func pushConfigurationToEngine() async {
        await engine.updateConfiguration(
            endpoints: openProject?.endpoints ?? [],
            globalDelayMs: openProject?.serverConfiguration.globalDelayMs ?? 0,
            journey: openProject?.activeJourney
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
