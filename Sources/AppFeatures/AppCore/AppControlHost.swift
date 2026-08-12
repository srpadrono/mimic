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
        await perform(command)
    }

    // MARK: - Execution on the main actor

    /// Answers a command against the live session.
    ///
    /// Asynchronous for one reason: four of the project-lifecycle commands have to reach the store —
    /// three to check that the reference they were given names a real project, `projectExport` to read
    /// a document this session does not have open — and the store is asynchronous. Everything else
    /// here is a read of session state and never suspends, so it still runs to completion in one hop
    /// with nothing able to interleave.
    private func perform(_ command: ControlCommand) async -> ControlResponse {
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
                let configured = await perform(.serverConfigure(port: port, globalDelayMs: nil))
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
            guard let journey = appState.activeJourney else { return .failure(.noActiveJourney) }
            // Awaited, and the *engine's* answer is what is reported. This used to dispatch the
            // advance and then read `activeJourneyStatus` — the runtime's mirror of the cursor, which
            // the advance it had just requested had not reached yet. So the reply carried the position
            // from before the command at best, and no position at all on a script's first advance,
            // which is when nothing has populated the mirror. `journeyRestart` above never had the
            // problem because it builds its status from the journey rather than reading the mirror.
            let advanced = await appState.advanceActiveJourneyReportingStatus()
            return .success(.init(
                message: "Advanced the journey.",
                // The fallback is the same one `journeyRestart` and `journeyStatus` use: with no
                // journey loaded into the engine there is no cursor to report, and the journey as it
                // stands — not yet started — is the honest answer rather than an omitted field.
                journeyStatus: advanced ?? JourneyStatus.make(journey: journey, state: nil)
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
            return await performProjectCommand(command, appState: appState)

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

    /// Project selection is asynchronous in the app (autosave, recents, GRDB), so these commands are
    /// *initiated* here and confirmed by the caller with a follow-up `state` — the same contract as
    /// `serverStart`.
    ///
    /// What is *not* optimistic is whether the reference names anything. Resolving it against the
    /// store is the one part that can be answered before replying, and it is the part a script
    /// branches on.
    private func performProjectCommand(
        _ command: ControlCommand,
        appState: AppState
    ) async -> ControlResponse {
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
            do {
                let id = try await resolveStoredProjectID(ref, appState: appState)
                appState.openProject(id: id)
                return .success(.message("Opening project."))
            } catch {
                return failureResponse(for: error)
            }

        case .projectClose:
            appState.closeProject()
            return .success(.message("Closed the project."))

        case let .projectDelete(ref):
            do {
                let id = try await resolveStoredProjectID(ref, appState: appState)
                appState.deleteProject(id: id)
                return .success(.message("Deleted the project."))
            } catch {
                return failureResponse(for: error)
            }

        case let .projectDuplicate(ref):
            do {
                let id = try await resolveStoredProjectID(ref, appState: appState)
                appState.duplicateProject(id: id)
                return .success(.message("Duplicating the project."))
            } catch {
                return failureResponse(for: error)
            }

        case let .projectExport(ref):
            guard let ref else {
                guard let project = appState.currentProject else { return .failure(.noProjectOpen) }
                return .success(.init(project: project))
            }
            // The reference used to be dropped on the floor — the arm bound no associated value — so
            // `mimic project export Other` returned whatever happened to be open and
            // `mimic project export Nonexistent` returned a document instead of `project.notFound`.
            //
            // The open project is still answered from the session rather than re-read: an export
            // taken straight after an edit has to contain it, and that edit is sitting in the
            // autosave debounce. Anything else exists only in the store.
            if let open = appState.currentProject, Self.matches(open, ref) {
                return .success(.init(project: open))
            }
            do {
                let stored = try await resolveStoredProject(ref)
                return .success(.init(project: stored))
            } catch {
                return failureResponse(for: error)
            }

        case let .projectImport(document, activate):
            // Same guard as the headless service: an import is the only way into a project that skips
            // the per-field validators, so it validates the whole document before anything is stored.
            do {
                try ProjectValidator.validate(document)
            } catch {
                return .failure(.validation(error))
            }
            // The write stays asynchronous, so the reply stays optimistic — but it is no longer
            // *silent*. This used to be `Task { try? await repository.save(document) }` right here,
            // which is the shape `ProjectDuplication` dissects: a store failure discarded and success
            // reported before the store was touched, so `mimic project import` exited 0 on an import
            // that never happened. `AppState.importProject` reports a refused write on the status the
            // window renders, and only opens the document once it is actually stored.
            appState.importProject(document, activate: activate)
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

    // MARK: - Resolving a project reference

    /// The id of the project a reference names, refused when nothing has it.
    ///
    /// The window used to take `ref.id` on trust and search only when it had a name instead, so no
    /// step of `projectOpen`, `projectDelete` or `projectDuplicate` ever checked that the id existed:
    /// `mimic project delete --id <any uuid>` answered "Deleted the project." having deleted nothing,
    /// while the identical command against a daemon reported `project.notFound`. The store is the only
    /// thing that can answer the question, and asking it is what the daemon does.
    ///
    /// Recents is deliberately not the source. It is a ten-entry `UserDefaults` cache reconciled
    /// against the store by an asynchronous refresh, so between launch and that refresh it can be
    /// missing projects the store holds — and a delete refused for a project that plainly exists is a
    /// worse answer than the one being fixed.
    ///
    /// The open project counts whether or not the store has caught up with it: `projectCreate` answers
    /// before its write lands, so a script that creates a project and immediately names it would
    /// otherwise be told it does not exist.
    private func resolveStoredProjectID(_ ref: ProjectRef, appState: AppState) async throws -> UUID {
        if let open = appState.currentProject, Self.matches(open, ref) { return open.id }

        // A script's previous command may still be writing. `mimic project create Foo` answers before
        // its insert lands, so `mimic project duplicate Foo` a moment later read a store that did not
        // have Foo yet and reported `project.notFound` for a project it had just been told about.
        // Waiting here costs nothing when nothing is in flight — see `ProjectWorkspace.storeWrites`.
        await appState.projects.awaitPendingStoreWrites()

        let stored = try await repository.allProjects()
        if let id = ref.id {
            guard stored.contains(where: { $0.id == id }) else {
                throw ControlError.projectNotFound(ref)
            }
            return id
        }
        return try Self.requireNamedProject(ref, in: stored).id
    }

    /// The whole document a reference names — endpoints and journeys included, which is what an export
    /// has to carry. Mirrors `MimicControlService.resolveStoredProject`, including which failure each
    /// dead end produces.
    private func resolveStoredProject(_ ref: ProjectRef) async throws -> MockProject {
        // Same wait, same reason as `resolveStoredProjectID` above: this is the read behind
        // `mimic project export`, and exporting a project created by the previous command has to
        // find it.
        await appState?.projects.awaitPendingStoreWrites()

        if let id = ref.id {
            do {
                return try await repository.load(id: id)
            } catch PersistenceError.projectNotFound {
                throw ControlError.projectNotFound(ref)
            }
            // Every other failure — a locked database, a row that will not decode — carries its own
            // diagnosis and is mapped by `failureResponse(for:)`. Catching `any Error` here would
            // report all of them as `project.notFound`, which is how "my projects vanished" ends up
            // with no diagnosis.
        }
        // `allProjects` returns stubs, so the name is matched against those and the winner loaded.
        let stored = try await repository.allProjects()
        let match = try Self.requireNamedProject(ref, in: stored)
        return try await repository.load(id: match.id)
    }

    private static func requireNamedProject(
        _ ref: ProjectRef,
        in stored: [MockProject]
    ) throws -> MockProject {
        guard let name = ref.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw ControlError.invalid("Provide a project id or name.")
        }
        let key = name.lowercased()
        guard let match = stored.first(where: { $0.name.lowercased() == key }) else {
            throw ControlError.projectNotFound(ref)
        }
        return match
    }

    /// Whether `project` is the one `ref` names. An id decides on its own when there is one; names are
    /// matched case-insensitively, which is what ``ProjectRef`` promises.
    private static func matches(_ project: MockProject, _ ref: ProjectRef) -> Bool {
        if let id = ref.id { return project.id == id }
        guard let name = ref.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return false
        }
        return project.name.caseInsensitiveCompare(name) == .orderedSame
    }

    /// Turns a thrown failure into the reply the headless service gives for the same one, so a script
    /// branching on `error.code` gets the same string from either host.
    private func failureResponse(for error: any Error) -> ControlResponse {
        if let error = error as? ControlError { return .failure(error) }
        if let error = error as? PersistenceError {
            return .failure(ControlError(
                code: "persistence.failure",
                message: error.localizedDescription
            ))
        }
        return .failure(.internalFailure(error.localizedDescription))
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
