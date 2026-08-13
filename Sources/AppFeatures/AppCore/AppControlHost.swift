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
    /// Held across the suspension in `serverStart`, so two lifecycle *commands* cannot interleave.
    /// `MimicControlService` carries the same flag for the same reason; the two hosts are meant to
    /// answer identically and this is one of the places that has to be written twice to stay true.
    ///
    /// It covers less here than it does there, and the difference is the whole of the defect the two
    /// lifecycle arms below were rewritten for. The service holds this flag across `engine.start`
    /// itself, so it is set for as long as the bind takes. This one is released on `defer` when the
    /// arm returns — and `AppState.startServer()` returns as soon as the runtime has published
    /// `.starting`, with the bind still ahead of it in a task of its own. The transition therefore
    /// outlives the command, and only `MockServerRuntime.serverState` knows about it. Both arms read
    /// that state as well as this flag.
    private var isChangingServerState = false
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
    /// Asynchronous because several arms have to leave the main actor: four of the project-lifecycle
    /// commands reach the store — three to check that the reference they were given names a real
    /// project, `projectExport` to read a document this session does not have open — `serverStart`
    /// awaits a recursive `serverConfigure` when it is given a port, and `journeyAdvance` and
    /// `journeyActivate` both await the engine for the cursor they report.
    ///
    /// **Which arms suspend is the interesting part**, and this comment used to say none of them did:
    /// "a read of session state … runs to completion in one hop with nothing able to interleave". It
    /// was true before the store lookups landed and it is not now, and it was asserting exactly the
    /// atomicity the control server's concurrency safety rested on. Two concurrent `serverStart`s can
    /// interleave across that `await`, which is why the arm carries its own guard below — the same one
    /// `MimicControlService` grew in the same change, refusing with `server.busy` rather than queueing.
    ///
    /// It then said "everything else here is still a single-hop read", and that had already stopped
    /// being true: the `journeyAdvance` arm awaits the engine, and does so precisely because reading
    /// the runtime's mirror in one hop answered with the cursor from before the command.
    ///
    /// Four places in the switch below reach an `await`, and they are the four named above:
    /// `serverStart` (only when it was given a port), `journeyActivate`, `journeyAdvance`, and the
    /// single arm that hands the eight project-lifecycle commands to `performProjectCommand`. Every
    /// other arm is a single-hop read of session state. Do not restate that as a count anywhere else —
    /// this is the one place it is written down, and the arms are named so a reader can check it
    /// against the switch rather than against another comment.
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
            // Mode comes from the same source the discovery file uses, so the two cannot disagree;
            // the sentence around it is `ControlMessages`', so neither can the two hosts.
            return .success(.message(ControlMessages.ping(mode: mode, pid: pid)))

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
            // Set before the first suspension below, cleared however this arm leaves. Two scripts —
            // or one script racing itself — asking to start at once would otherwise both cross the
            // `await` on `serverConfigure` and both call `startServer()`. Refused rather than queued,
            // and with the same code the headless service uses, so a caller gets one answer to this
            // whatever it is talking to.
            guard !isChangingServerState else { return .failure(.serverBusy) }
            isChangingServerState = true
            defer { isChangingServerState = false }

            // A lifecycle change already in flight. The flag above cannot see this one: it is
            // released on `defer` when *this* arm exits, while `MockServerRuntime` stays `.starting`
            // until the engine binds inside a task of its own — so the transition outlives the
            // command that began it. `startServer()` accepts a start only from `.stopped` or
            // `.error` and drops it otherwise, which is what made the old unconditional "Starting the
            // server on port N." a report of something that had not happened.
            //
            // Refused with the code the headless service uses for the same collision, rather than
            // queued: `server.busy` maps to 409, and a caller that is told to poll `server status`
            // has everything it needs to retry. Switched with no `default` so a new `ServerState`
            // case cannot be added without deciding which side of this it falls on.
            switch appState.serverState {
            case .starting, .stopping:
                return .failure(.serverBusy)
            case .stopped, .running, .error:
                break
            }

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
            // Already up. Read after the `await` above, not before it: a port supplied here is still
            // written to the project — which is what `MimicControlService.startServer` does in the
            // same position — and only then is the caller told the bind it asked for is not going to
            // happen. Word for word the service's sentence, so a script gets one answer from either.
            if case let .running(runningPort) = appState.serverState {
                return .success(.init(
                    message: ControlMessages.serverAlreadyRunning(port: runningPort),
                    server: makeServerStatus(appState)
                ))
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
            // No suspension in this arm today, so the guard is about the *other* one: a stop arriving
            // while a start is mid-`await` would otherwise tell the engine to stop a server the start
            // has not asked for yet.
            guard !isChangingServerState else { return .failure(.serverBusy) }
            // The reply is decided by the state the stop is applied to, because
            // `MockServerRuntime.stopServer()` acts only on `.running` and drops the command
            // silently everywhere else. This arm used to answer "Stopping the server." regardless,
            // so `mimic server start` followed by `mimic server stop` — the two arriving well inside
            // the window where the engine has not bound yet and the state is `.starting` — reported a
            // stop that never happened and left the server up. The guard above does not cover that
            // window: it is released on `defer` when the start arm returns, and the start arm returns
            // before the engine binds.
            switch appState.serverState {
            case .running:
                appState.stopServer()
                // Still optimistic — the runtime shuts the engine down from a task — but the stop was
                // accepted, which is the only thing this sentence claims.
                return .success(.init(
                    message: "Stopping the server.",
                    server: makeServerStatus(appState)
                ))
            case .starting, .stopping:
                // Refused rather than dropped or queued, with the code and the sentence the headless
                // service uses for the same collision. The runtime cannot cancel a bind in progress,
                // and a caller told "stopping" would never poll again.
                return .failure(.serverBusy)
            case .stopped, .error:
                // Nothing to stop, in the sentence `ControlMessages` holds for both hosts.
                return .success(.init(
                    message: ControlMessages.serverNotRunning,
                    server: makeServerStatus(appState)
                ))
            }

        case .serverStatus:
            return .success(.init(server: makeServerStatus(appState)))

        // MARK: Journeys — runtime

        case let .journeyActivate(ref):
            guard let project = appState.currentProject else { return .failure(.noProjectOpen) }
            guard let ref else {
                appState.activateJourney(id: nil)
                return .success(.message(ControlMessages.journeyCleared))
            }
            guard let journey = project.journey(matching: ref) else {
                return .failure(.journeyNotFound(ref))
            }
            appState.activateJourney(id: journey.id)
            // The engine's own cursor, awaited — not a fabricated one.
            //
            // This used to answer `JourneyStatus.make(journey:state:nil)`, which reports a run that
            // has not started, whatever the engine was actually doing. `MockRouteStore.update` keeps
            // the run state when the same journey with the same steps is pushed again, so a harness
            // re-activating between test cases was told step 1 was next while the engine was mid-run
            // — and the reply was built from the document, so nothing about the engine could ever
            // have changed it.
            //
            // Routed through the runtime rather than asking the engine directly because activation
            // reaches the engine from a task: `activateJourney` writes `currentProject`, whose `didSet`
            // pushes the project, and a status read issued straight afterwards gets to the engine actor
            // first and reports the journey that was there before. See
            // `AppState.journeyStatusAfterPendingMockUpdates()`.
            let engineStatus = await appState.journeyStatusAfterPendingMockUpdates()
            return .success(.init(
                message: ControlMessages.journeyActivated(
                    name: journey.name,
                    stepCount: journey.steps.count
                ),
                journey: journey,
                // The same fallback `journeyStatus` and `journeyRestart` beside it use: with no journey
                // loaded into the engine there is no cursor to report, and the journey as it stands is
                // the honest answer rather than an omitted field.
                journeyStatus: engineStatus ?? JourneyStatus.make(journey: journey, state: nil)
            ))

        case .journeyRestart:
            guard appState.currentProject != nil else { return .failure(.noProjectOpen) }
            guard let journey = appState.activeJourney else { return .failure(.noActiveJourney) }
            appState.restartActiveJourney()
            return .success(.init(
                message: ControlMessages.journeyRestarted(name: journey.name),
                // Built from the document, and that is a *remaining* gap rather than a decision.
                // `MockServerRuntime.restartJourney()` dispatches, and the engine hands back the cursor
                // the restart produced — which nothing here reads. So this reports a fresh run because
                // a restart is *supposed* to produce one, not because the engine said it did, and the
                // reply happens to be right today for exactly the reason `journeyActivate`'s was
                // wrong: nobody asked. `advanceJourneyReportingStatus()` is the shape a fix takes, and
                // the arm above now uses the equivalent for activation.
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
            // Filter, trim and redaction are `HostReport`'s, so this arm cannot answer a different
            // selection — or a less redacted one — than the headless service does. `appState.requestLogs`
            // keeps the real values, because in the app's own window they are the developer's own
            // traffic on the developer's own screen; it is handing them to a *caller* that needs the
            // guard, and that is the path this goes through.
            return .success(.init(
                logs: HostReport.requestLog(
                    from: appState.requestLogs,
                    limit: limit,
                    unmatchedOnly: unmatchedOnly
                )
            ))

        case .logClear:
            let count = appState.requestLogs.count
            appState.requestLogs = []
            return .success(.message(ControlMessages.logCleared(count: count)))

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
            // The store, counted the way `MimicControlService.projectSummaries` counts it.
            //
            // This used to map `AppState.recentProjects`, and recents cannot answer the question: it
            // is a ten-entry `UserDefaults` cache holding an id, a name and a last-opened date, so
            // every other field in a `ProjectSummary` had to be invented. Every project the session
            // did not have open was reported as serving on `ServerConfiguration.default.port` with a
            // zero delay, no endpoints, no journeys and no active journey, and *every* row — the open
            // one included — carried `modifiedAt: Date()`, the instant of the call. A script that
            // listed projects to find the port to point a client at was handed 8080 for all of them,
            // and the identical command against a daemon answered correctly. The suite that was
            // supposed to catch it compared which fields were populated rather than what was in them.
            //
            // Same wait as `resolveStoredProjectID` below, and for the same reason: `projectCreate`
            // answers before its insert lands, so listing straight after creating has to see it.
            await appState.projects.awaitPendingStoreWrites()
            do {
                let stored = try await repository.allProjects()
                // `allProjects` returns stubs with no children; the store counts them in two grouped
                // queries. Merging those counts onto the stubs is `HostReport.projectSummaries`,
                // shared with the service — including that a project with neither child has no row
                // in `counts` and the stub's own zeroes are already the right answer.
                let counts = (try? await repository.projectCounts()) ?? [:]
                // The open project is answered from the session rather than from the store, for the
                // reason `projectExport` is: an edit made a moment ago is still sitting in the
                // autosave debounce, so the stored row is the one that can be behind. That overlay
                // is the whole of what this host passes and the service does not.
                return .success(.init(projects: HostReport.projectSummaries(
                    of: stored,
                    counts: counts,
                    openProject: appState.currentProject
                )))
            } catch {
                return failureResponse(for: error)
            }

        case let .projectCreate(name, port):
            guard let trimmed = name.nilIfEmpty else { return .failure(.emptyProjectName) }
            // Validated where `MimicControlService.run` validates it, and where the `serverStart` arm
            // above already validated the same value. This arm did not, and nothing downstream does:
            // `AppState.createProject` hands the number straight to `ProjectWorkspace.createProject`,
            // which builds a `ServerConfiguration` from it and saves it. So `mimic project create X
            // --port 70000` was accepted here, stored, and refused by a daemon for the same command.
            if let port {
                do {
                    try EndpointValidator.validatePort(port)
                } catch {
                    return .failure(.validation(error))
                }
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
            if let open = appState.currentProject, open.matches(ref) {
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
            // Present tense, and that is the whole of the declared difference from the service: the
            // save above is still in flight, so this reports what was accepted rather than what is
            // stored. The counted tail is the same sentence in both, built once.
            return .success(.init(
                message: ControlMessages.projectImporting(
                    name: document.name,
                    endpointCount: document.endpoints.count,
                    journeyCount: document.journeys.count
                ),
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

    // `ControlError.serverBusy` used to be declared here, and again in `MimicControlService`, with a
    // comment promising the two said the same thing word for word. It lives in Domain now, so the
    // promise is the declaration.

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
        if let open = appState.currentProject, open.matches(ref) { return open.id }

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
        return try MockProject.requireNamed(ref, in: stored).id
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
        // The matching itself is `MockProject.requireNamed` in Domain — the trim, the fold, the
        // first-match rule and which of `request.invalid` / `project.notFound` each dead end
        // produces. It was a private copy here and another inside
        // `MimicControlService.resolveStoredProject`.
        let stored = try await repository.allProjects()
        let match = try MockProject.requireNamed(ref, in: stored)
        return try await repository.load(id: match.id)
    }

    /// Turns a thrown failure into the reply the headless service gives for the same one, so a script
    /// branching on `error.code` gets the same string from either host.
    ///
    /// The two branches that can be shared are: `ControlError` passes through, and a store failure is
    /// `ControlError.persistenceFailure` — the same constructor `MimicControlService.execute` uses,
    /// rather than the `"persistence.failure"` string literal each of them used to spell out. The
    /// *shape* stays duplicated because it cannot move: `PersistenceError` lives in `Persistence`,
    /// which Domain does not and must not see.
    private func failureResponse(for error: any Error) -> ControlResponse {
        if let error = error as? ControlError { return .failure(error) }
        if let error = error as? PersistenceError { return .failure(.persistenceFailure(error)) }
        return .failure(.internalFailure(error.localizedDescription))
    }

    // MARK: - Reporting

    private var pid: Int { Int(ProcessInfo.processInfo.processIdentifier) }

    private var mode: String { HeadlessMode.isEnabled ? "headless" : "app" }

    /// This session's state, in the shape the wire uses.
    ///
    /// Everything below the parameters — the project summary, the endpoint and journey counts — is
    /// ``HostReport/state(appVersion:mode:pid:server:project:activeJourney:requestLogCount:)``, so
    /// the window cannot derive them differently from the headless service. What stays here is what
    /// only this host can answer: where its version comes from (`Bundle.main`, which a service is
    /// told instead), and that the live cursor is read from the runtime with the not-yet-started
    /// journey as the fallback.
    private func makeState(_ appState: AppState) -> ControlState {
        HostReport.state(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            mode: mode,
            pid: pid,
            server: makeServerStatus(appState),
            project: appState.currentProject,
            activeJourney: appState.activeJourneyStatus
                ?? appState.activeJourney.map { JourneyStatus.make(journey: $0, state: nil) },
            requestLogCount: appState.requestLogs.count
        )
    }

    /// The session's server state, in the shape the wire uses.
    ///
    /// Only the values are this host's to read; the switch that turns them into a report — the state
    /// string, whether a `baseURL` is present and what it says — is shared with the service, where the
    /// identical switch used to sit.
    ///
    /// `errorCode` is the one field `HostReport` cannot derive: `ServerState.error` carries a sentence
    /// and nothing else, so the code comes from the runtime, which is what saw the engine's error. It
    /// is what makes a failed bind reportable at all from this host — `serverStart` answers before the
    /// bind completes, so `mimic server status` is the only place the failure can surface, and it used
    /// to surface as `stopped` with no `baseURL`, which is exactly what a server nobody started looks
    /// like.
    private func makeServerStatus(_ appState: AppState) -> ServerStatusReport {
        var report = HostReport.serverStatus(
            state: appState.serverState,
            configuredPort: appState.serverConfiguration.port,
            globalDelayMs: appState.serverConfiguration.globalDelayMs
        )
        report.errorCode = appState.serverStartFailure?.code
        return report
    }
}
