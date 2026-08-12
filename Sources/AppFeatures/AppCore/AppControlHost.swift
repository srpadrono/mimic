import ControlPlane
import Domain
import Foundation
import Persistence

/// Lets `mimic` drive the *running app* — the same session the window shows.
///
/// Without this the CLI would need its own instance, and an agent's changes would be invisible to
/// the developer watching the screen. Instead the app hosts the control API and this adapter maps
/// commands onto the live ``AppState``, so an endpoint created from a script appears in the sidebar
/// immediately and a journey activated in the UI is what the CLI reports.
///
/// Project-scoped commands go through `ProjectCommandExecutor`, exactly as they do in the headless
/// service; only the genuinely stateful minority is implemented here.
@MainActor
final class AppControlHost: ControlHost {

    private weak var appState: AppState?
    private let repository: any ProjectRepository

    init(appState: AppState, repository: any ProjectRepository) {
        self.appState = appState
        self.repository = repository
    }

    nonisolated func execute(_ command: ControlCommand) async -> ControlResponse {
        await MainActor.run { [weak self] in
            guard let self else {
                return ControlResponse.failure(.internalFailure("The Mimic session is no longer available."))
            }
            return self.perform(command)
        }
    }

    // MARK: - Synchronous execution on the main actor

    private func perform(_ command: ControlCommand) -> ControlResponse {
        guard let appState else {
            return .failure(.internalFailure("The Mimic session is no longer available."))
        }

        // Project-scoped: one implementation, shared with the CLI and the headless service.
        if var project = appState.currentProject {
            do {
                if let outcome = try ProjectCommandExecutor.apply(command, to: &project) {
                    if outcome.didMutate {
                        project.modifiedAt = Date()
                        appState.currentProject = project
                        appState.scheduleAutosave()
                    }
                    return .success(outcome.result)
                }
            } catch let error as ControlError {
                return .failure(error)
            } catch {
                return .failure(.internalFailure(error.localizedDescription))
            }
        }

        // Project-scoped, and nothing is open. `ProjectCommandExecutor` would have handled every one
        // of these; it declined only because there is no project to apply them to.
        //
        // This used to be a twenty-six-case list at the bottom of the switch below, mirrored case for
        // case by `MimicControlService` and complemented by the executor's own twenty-one — one fact
        // written three times and kept in agreement by hand. `CommandKind.scope` is that fact now,
        // and its switch carries no `default`, so a command added later still cannot compile until
        // somebody decides which side of the line it falls on, which is the only thing naming
        // twenty-six cases here was buying.
        guard command.kind.scope == .host else { return .failure(.noProjectOpen) }

        switch command {
        case .ping:
            // Mode comes from the same source the discovery file uses, so the two cannot disagree.
            return .success(.message(
                "Mimic control plane \(ControlAPI.version) (\(mode), pid \(pid))."
            ))

        case .describeCommands:
            return .success(.init(commands: CommandCatalog.descriptors))

        case .state:
            return .success(.init(state: makeState(appState)))

        case let .reset(scope):
            // The reply is built by `ControlMessages`, the same way the headless service builds it.
            // This used to report `Reset \(scope.rawValue).` — true of the request, silent about the
            // instance, and different from what the same command answers against a daemon. A script
            // driving both got two answers to one question.
            var clearedLogEntries: Int?
            if scope == .logs || scope == .all {
                clearedLogEntries = appState.requestLogs.count
                appState.requestLogs = []
            }

            var restartedJourneyName: String?
            if scope == .journey || scope == .all {
                // Read before the restart is requested: it is dispatched to the engine and does not
                // report back synchronously, and the journey being rewound is the one active now.
                restartedJourneyName = appState.activeJourney?.name
                appState.restartActiveJourney()
            }

            return .success(.init(
                message: ControlMessages.reset(
                    clearedLogEntries: clearedLogEntries,
                    restartedJourneyName: restartedJourneyName
                ),
                state: makeState(appState)
            ))

        // MARK: Server

        case let .serverStart(port):
            guard appState.currentProject != nil else { return .failure(.noProjectOpen) }
            if let port {
                // Through `.serverConfigure`, not by writing the runtime's copy: a port supplied to
                // `mimic server start --port` is a change to the project, and validating it here and
                // then applying it somewhere the project cannot see is how the two came apart. The
                // executor validates too, but keeping the check here means the caller gets
                // `port.invalid` rather than a start that quietly used the old port.
                do {
                    try EndpointValidator.validatePort(port)
                } catch {
                    return .failure(.validation(error))
                }
                let configured = perform(.serverConfigure(port: port, globalDelayMs: nil))
                guard configured.ok else { return configured }
            }
            appState.startServer()
            // The runtime starts asynchronously, so report the intent rather than claiming a state
            // that has not been reached. `mimic server status` is the way to confirm.
            return .success(.init(
                message: "Starting the server on port \(appState.serverConfiguration.port). "
                    + "Poll `mimic server status` to confirm.",
                server: makeServerStatus(appState)
            ))

        case .serverStop:
            appState.stopServer()
            return .success(.init(message: "Stopping the server.", server: makeServerStatus(appState)))

        case .serverStatus:
            return .success(.init(server: makeServerStatus(appState)))

        // MARK: Journeys — runtime

        case let .journeyActivate(ref):
            guard let project = appState.currentProject else { return .failure(.noProjectOpen) }
            guard let ref else {
                appState.activateJourney(id: nil)
                return .success(.message("Cleared the active journey; endpoints now answer directly."))
            }
            guard let journey = project.journey(matching: ref) else {
                return .failure(.journeyNotFound(ref))
            }
            appState.activateJourney(id: journey.id)
            return .success(.init(
                message: "Activated journey \"\(journey.name)\" (\(journey.steps.count) steps).",
                journey: journey,
                journeyStatus: JourneyStatus.make(journey: journey, state: nil)
            ))

        case .journeyRestart:
            guard appState.currentProject != nil else { return .failure(.noProjectOpen) }
            guard let journey = appState.activeJourney else { return .failure(.noActiveJourney) }
            appState.restartActiveJourney()
            return .success(.init(
                message: "Restarted journey \"\(journey.name)\".",
                journeyStatus: JourneyStatus.make(journey: journey, state: nil)
            ))

        case .journeyAdvance:
            guard appState.currentProject != nil else { return .failure(.noProjectOpen) }
            guard appState.activeJourney != nil else { return .failure(.noActiveJourney) }
            appState.advanceActiveJourney()
            return .success(.init(
                message: "Advanced the journey.",
                journeyStatus: appState.activeJourneyStatus
            ))

        case .journeyStatus:
            guard appState.currentProject != nil else { return .failure(.noProjectOpen) }
            guard let journey = appState.activeJourney else { return .failure(.noActiveJourney) }
            return .success(.init(
                journeyStatus: appState.activeJourneyStatus
                    ?? JourneyStatus.make(journey: journey, state: nil)
            ))

        // MARK: Logs

        case let .logList(limit, unmatchedOnly):
            var entries = appState.requestLogs
            if unmatchedOnly == true {
                entries = entries.filter(\.outcome.isMissingConfiguration)
            }
            if let limit { entries = Array(entries.suffix(max(0, limit))) }
            // Redacted on the way out. `appState.requestLogs` keeps the real values, because in the
            // app's own window they are the developer's own traffic on the developer's own screen —
            // it is handing them to a *caller* that needs the guard.
            return .success(.init(logs: entries.map { $0.redactingCredentials() }))

        case .logClear:
            let count = appState.requestLogs.count
            appState.requestLogs = []
            return .success(.message("Cleared \(count) request log \(count == 1 ? "entry" : "entries")."))

        // MARK: Projects — these touch the store, so they are answered asynchronously

        case .projectList, .projectCreate, .projectOpen, .projectClose, .projectDelete,
             .projectDuplicate, .projectExport, .projectImport:
            return performProjectCommand(command, appState: appState)

        // Declared host-scoped, not implemented above.
        //
        // Unreachable while `CommandKind.scope` and this switch agree, and the compiler cannot check
        // that they do: the guard above narrows by `CommandKind` while the switch is over
        // `ControlCommand`. Naming the real problem beats falling through to `noProjectOpen`, which
        // would tell the caller to open a project they already have open — the misdirection the old
        // twenty-six-case list existed to prevent.
        default:
            return .failure(.internalFailure(
                "\(command.kind.rawValue) is host-scoped but the app's control host does not implement it."
            ))
        }
    }

    // MARK: - Project lifecycle

    /// Project selection and store access are asynchronous in the app (autosave, recents, GRDB), but
    /// a control call must answer synchronously. These commands are therefore *initiated* here and
    /// confirmed by the caller with a follow-up `state` — the same contract as `serverStart`.
    private func performProjectCommand(_ command: ControlCommand, appState: AppState) -> ControlResponse {
        switch command {
        case .projectList:
            // Recents are the app's own listing and are already loaded, so this one can answer fully.
            let summaries = appState.recentProjects.map { entry in
                ProjectSummary(
                    id: entry.id,
                    name: entry.name,
                    port: appState.currentProject?.id == entry.id
                        ? appState.serverConfiguration.port
                        : ServerConfiguration.default.port,
                    globalDelayMs: appState.currentProject?.id == entry.id
                        ? appState.serverConfiguration.globalDelayMs
                        : 0,
                    endpointCount: appState.currentProject?.id == entry.id
                        ? appState.currentProject?.endpoints.count ?? 0
                        : 0,
                    journeyCount: appState.currentProject?.id == entry.id
                        ? appState.currentProject?.journeys.count ?? 0
                        : 0,
                    activeJourneyID: appState.currentProject?.id == entry.id
                        ? appState.currentProject?.activeJourneyID
                        : nil,
                    modifiedAt: Date()
                )
            }
            return .success(.init(projects: summaries))

        case let .projectCreate(name, port):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure(.invalid("Project name must not be empty."))
            }
            appState.createProject(name: trimmed, port: port ?? ServerConfiguration.default.port)
            return .success(.message("Creating and opening project \"\(trimmed)\"."))

        case let .projectOpen(ref):
            guard let id = ref.id ?? appState.recentProjects.first(where: {
                $0.name.caseInsensitiveCompare(ref.name ?? "") == .orderedSame
            })?.id else {
                return .failure(.projectNotFound(ref))
            }
            appState.openProject(id: id)
            return .success(.message("Opening project."))

        case .projectClose:
            appState.closeProject()
            return .success(.message("Closed the project."))

        case let .projectDelete(ref):
            guard let id = ref.id ?? appState.recentProjects.first(where: {
                $0.name.caseInsensitiveCompare(ref.name ?? "") == .orderedSame
            })?.id else {
                return .failure(.projectNotFound(ref))
            }
            appState.deleteProject(id: id)
            return .success(.message("Deleted the project."))

        case let .projectDuplicate(ref):
            guard let id = ref.id ?? appState.recentProjects.first(where: {
                $0.name.caseInsensitiveCompare(ref.name ?? "") == .orderedSame
            })?.id else {
                return .failure(.projectNotFound(ref))
            }
            appState.duplicateProject(id: id)
            return .success(.message("Duplicating the project."))

        case .projectExport:
            guard let project = appState.currentProject else { return .failure(.noProjectOpen) }
            return .success(.init(project: project))

        case let .projectImport(document, activate):
            // Same guard as the headless service: an import is the only way into a project that skips
            // the per-field validators, so it validates the whole document before anything is stored.
            do {
                try ProjectValidator.validate(document)
            } catch {
                return .failure(.validation(error))
            }
            let repository = repository
            Task {
                try? await repository.save(document)
                if activate {
                    await MainActor.run { appState.openProject(id: document.id) }
                }
            }
            return .success(.init(
                message: "Importing project \"\(document.name)\" "
                    + "(\(document.endpoints.count) endpoints, \(document.journeys.count) journeys).",
                project: document
            ))

        // The caller has already narrowed to the eight project-lifecycle commands above, and nothing
        // in the type system says so — this takes a whole `ControlCommand`. Closing the switch would
        // mean naming the other thirty-nine cases, which is a fourth hand-written partition of the
        // surface and precisely what `CommandKind.scope` exists to remove. So it stays a `default`,
        // and names the command rather than reporting a bare "unhandled".
        default:
            return .failure(.internalFailure(
                "\(command.kind.rawValue) is not a project-lifecycle command."
            ))
        }
    }

    // MARK: - Reporting

    private var pid: Int { Int(ProcessInfo.processInfo.processIdentifier) }

    private var mode: String { HeadlessMode.isEnabled ? "headless" : "app" }

    private func makeState(_ appState: AppState) -> ControlState {
        ControlState(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            mode: HeadlessMode.isEnabled ? "headless" : "app",
            pid: pid,
            server: makeServerStatus(appState),
            project: appState.currentProject.map(ProjectSummary.init),
            endpointCount: appState.currentProject?.endpoints.count ?? 0,
            journeyCount: appState.currentProject?.journeys.count ?? 0,
            activeJourney: appState.activeJourneyStatus
                ?? appState.activeJourney.map { JourneyStatus.make(journey: $0, state: nil) },
            requestLogCount: appState.requestLogs.count
        )
    }

    private func makeServerStatus(_ appState: AppState) -> ServerStatusReport {
        let port = appState.serverConfiguration.port
        let delay = appState.serverConfiguration.globalDelayMs

        switch appState.serverState {
        case let .running(runningPort):
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
}
