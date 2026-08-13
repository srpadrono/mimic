import Domain
import Foundation
import MockServerEngine
import Observation

/// Abstraction over the embedded server engine so the runtime can be driven by a fake in tests.
protocol MockServerEngineProtocol: Sendable {
    var logStream: AsyncStream<RequestLog> { get }
    func start(configuration: ServerConfiguration) async throws
    func stop() async throws
    func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async
    func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int, journey: Journey?) async
    func updateConfiguration(
        endpoints: [Endpoint],
        globalDelayMs: Int,
        journey: Journey?,
        activationEpoch: Int
    ) async
    func restartJourney() async -> JourneyStatus?
    func advanceJourney() async -> JourneyStatus?
    func journeyStatus() async -> JourneyStatus?
}

extension MockServerEngine: MockServerEngineProtocol {}

/// Journey support is defaulted so a test double only implements the parts it exercises.
///
/// The defaults are honest rather than convenient: a fake that ignores journeys reports *no* journey,
/// which is exactly what it has. Silently returning a fabricated status would let a runtime bug pass.
extension MockServerEngineProtocol {
    func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int, journey: Journey?) async {
        await updateConfiguration(endpoints: endpoints, globalDelayMs: globalDelayMs)
    }

    /// Defaulted so a fake that ignores journeys does not have to know what an activation epoch is.
    /// Dropping the count is the honest default for such a double: it keeps no run to reset.
    func updateConfiguration(
        endpoints: [Endpoint],
        globalDelayMs: Int,
        journey: Journey?,
        activationEpoch: Int
    ) async {
        await updateConfiguration(endpoints: endpoints, globalDelayMs: globalDelayMs, journey: journey)
    }

    func restartJourney() async -> JourneyStatus? { nil }
    func advanceJourney() async -> JourneyStatus? { nil }
    func journeyStatus() async -> JourneyStatus? { nil }
}

/// MainActor-facing controller for the server lifecycle, configuration, the live request log, and
/// the active journey's run state. It owns the engine and drains its single `logStream` for the
/// engine's lifetime.
@Observable
@MainActor
final class MockServerRuntime {
    var serverState: ServerState = .stopped
    var serverConfiguration: ServerConfiguration = .default
    var requestLogs: [RequestLog] = []
    var portConflictAlert: PortConflictAlertData?
    var genericStartError: String?

    /// Why the last start attempt failed, with the code a script branches on — `nil` once a new
    /// attempt begins, and never set without ``serverState`` becoming `.error` in the same hop.
    ///
    /// Held apart from the two properties above because those are *presentation* state: `WorkspaceView`
    /// sets `portConflictAlert` back to `nil` the moment the user dismisses the sheet, and a headless
    /// run renders neither of them. `mimic server status` has to be able to read the failure whether or
    /// not a window happened to show it, which is what `AppControlHost` reports this on.
    var startFailure: ControlError?

    /// Mirror of the engine's journey cursor.
    ///
    /// The engine is the authority — it advances the cursor as it serves — so this is refreshed after
    /// every configuration change, every runtime control, and every logged request. Views read it
    /// synchronously; nothing in a view body has to await an actor.
    var journeyStatus: JourneyStatus?

    static let maxRequestLogEntries = 1000

    private let engine: any MockServerEngineProtocol

    init(engine: any MockServerEngineProtocol = MockServerEngine()) {
        self.engine = engine
        // Drain the engine's single log stream on the main actor. Starting the consumer here — before
        // the server can serve a request — guarantees no startup logs are missed. The loop ends
        // naturally when the engine finishes its stream on deinit, so no explicit cancellation is needed
        // (and `[weak self]` avoids retaining the runtime past its own lifetime).
        let stream = engine.logStream
        Task { [weak self] in
            for await entry in stream {
                self?.appendLog(entry)
                // A served request may have advanced the journey, so the mirror is refreshed here
                // rather than on a timer.
                self?.refreshJourneyStatus()
            }
        }
    }

    /// Starts the engine — from `.stopped` or `.error`, and from nowhere else.
    ///
    /// **A start requested from any other state is dropped, and nothing is reported.** That is the
    /// right shape for the window, which is the caller this was written for: `ServerToggleButton`
    /// sends `onStart` only from those two states and is `.disabled(isTransitioning)` in between, so
    /// the drop is unreachable from the button. It is a trap for anything that has to *answer* the
    /// request instead — see the note on ``stopServer()``.
    ///
    /// When it does accept, the state is `.starting` — not `.running` — by the time this returns. The
    /// engine binds inside the task below, so "started" is never true synchronously and no caller may
    /// report it as if it were.
    ///
    /// **The configuration is captured once, before the bind.** ``serverConfiguration`` is a mutable
    /// property of this object and `.serverConfigure` is *project*-scoped, so `AppControlHost` applies
    /// it through `ProjectCommandExecutor` with no lifecycle guard whatsoever — a `mimic server
    /// configure --port 9000` arriving while the bind is in flight lands here through
    /// `applyProject`. This method used to read `serverConfiguration` twice, once on either side of
    /// the `await`: it bound the port the first read carried and published the port the second one
    /// did. A script that configured while starting was handed a `baseURL` nothing was listening on.
    /// The `portInUse` arm never had the defect, because the port it reports comes off the error the
    /// engine threw rather than off this property.
    ///
    /// **A failure is recorded as well as rendered.** The bind fails after `serverStart` has already
    /// answered, so the state below and ``startFailure`` beside it are the only things a later
    /// `mimic server status` can read; a port conflict used to leave `.stopped`, which is what a
    /// server nobody started looks like.
    func startServer() {
        guard serverState == .stopped || serverState.isError else { return }
        serverState = .starting
        // A new attempt supersedes whatever the previous one failed with.
        startFailure = nil

        let configuration = serverConfiguration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await engine.start(configuration: configuration)
                serverState = .running(port: configuration.port)
            } catch let error as MockServerError {
                // The engine's own sentence goes into the state, so `mimic server status` reads the
                // engine's diagnosis rather than a paraphrase; the `--port` hint lives on
                // `startFailure`'s code and message, which is the half a script branches on.
                let message = error.localizedDescription
                serverState = .error(message)
                if case let .portInUse(port) = error {
                    startFailure = ControlError.serverPortInUse(port: port)
                    portConflictAlert = PortConflictAlertData(conflictingPort: port)
                } else {
                    startFailure = ControlError.serverStartFailed(message)
                    genericStartError = message
                }
            } catch {
                let message = error.localizedDescription
                serverState = .error(message)
                startFailure = ControlError.serverStartFailed(message)
                genericStartError = message
            }
        }
    }

    /// Stops the engine — from `.running`, and from nowhere else.
    ///
    /// The same contract as ``startServer()``, and the one that shipped a defect. `.starting` is the
    /// state *every* stop issued straight after a start arrives in, because `startServer()` publishes
    /// `.starting` and returns before the engine has bound; this method drops that stop, and
    /// `AppControlHost`'s `.serverStop` arm answered "Stopping the server." regardless. `mimic server
    /// start` followed by `mimic server stop` therefore reported a stop that never happened and left
    /// the server up.
    ///
    /// The contract here is unchanged — the window's button cannot reach the drop, and cancelling a
    /// bind that has not completed is not something this can do. What changed is the host: it reads
    /// ``serverState`` first and refuses a stop mid-transition with `server.busy` rather than
    /// claiming one it did not make. Any other caller that reports back owes the same check.
    func stopServer() {
        guard case .running = serverState else { return }
        serverState = .stopping

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await engine.stop()
            } catch {
                // Defensive fallback: surface a stopped state even if shutdown was noisy.
            }
            serverState = .stopped
        }
    }

    func retryStartOnNextPort(from conflictingPort: Int) {
        serverConfiguration.port = conflictingPort + 1
        portConflictAlert = nil
        startServer()
    }

    /// The configuration push most recently dispatched to the engine.
    ///
    /// Kept so a caller that has to *report* the engine's cursor can wait for the push it just caused
    /// to land. The push reaches the engine from an unstructured task, so a status read issued
    /// straight after it is a race the read wins: it hops to the engine actor before the push task has
    /// even started, and answers about the journey the engine still had.
    private var pendingMockUpdate: Task<Void, Never>?

    /// How many journey activations this session has performed, carried on every configuration push.
    ///
    /// The engine cannot tell a re-activation from a re-push by looking at the arguments: activating
    /// the journey that is already active sends the same endpoints and the same journey as any other
    /// mutation of the open document, and the two must behave differently — one restarts the run, the
    /// other must leave it alone. This count is how the caller says which happened.
    ///
    /// A count read by whatever push goes out next, rather than a flag set and cleared, because the
    /// activation does not issue the push: ``AppState/activateJourney(id:)`` writes `activeJourneyID`
    /// and the push leaves from `currentProject`'s `didSet`, which every mutation shares. A flag would
    /// have to survive that gap and be cleared on the far side; a count does not care how many pushes
    /// follow it, because `MockRouteStore` compares it against a high-water mark with `>`.
    private(set) var journeyActivationEpoch = 0

    /// Records that an activation is about to be pushed. Call this *before* the mutation that causes
    /// the push, and only when the activation will actually take effect. An id naming no journey
    /// still causes a push — `ProjectWorkspace.mutateCurrentProject` reassigns `currentProject`
    /// unconditionally and its `didSet` fires on every assignment — but that push is a re-push of an
    /// unchanged document, so it must carry the *un*raised count; raised, it would restart a run
    /// nobody asked to restart.
    func noteJourneyActivation() {
        journeyActivationEpoch += 1
    }

    func updateMocks(endpoints: [Endpoint], journey: Journey? = nil) {
        let globalDelayMs = serverConfiguration.globalDelayMs
        let activationEpoch = journeyActivationEpoch
        pendingMockUpdate = Task { @MainActor [weak self] in
            guard let self else { return }
            await engine.updateConfiguration(
                endpoints: endpoints,
                globalDelayMs: globalDelayMs,
                journey: journey,
                activationEpoch: activationEpoch
            )
            refreshJourneyStatus()
        }
    }

    func applyProject(_ project: MockProject?) {
        guard let project else {
            serverConfiguration = .default
            updateMocks(endpoints: [], journey: nil)
            return
        }

        serverConfiguration = project.serverConfiguration
        updateMocks(endpoints: project.endpoints, journey: project.activeJourney)
    }

    // MARK: - Journey runtime control

    /// Ticket taken by each mirror update before it suspends, and checked again before it writes.
    ///
    /// Every update below reaches the engine across an `await`, and each one used to do so from an
    /// unstructured `Task` of its own with no ordering between them — while the drain loop in `init`
    /// starts one per *served request*. Under a burst the answers therefore landed in whatever order
    /// the engine handed them back, so the last write could be the oldest read: the mirror settled on
    /// a stale cursor and stayed there until the next request happened to arrive and refresh it.
    ///
    /// Comparing the ticket makes the most recently *requested* update the one that lands and drops
    /// every answer a later request has already superseded. It orders the writes, which is the defect
    /// here; it cannot order two engine calls against each other, so a restart and a refresh issued
    /// together still race inside the engine — which owns the cursor either way.
    private var journeyStatusTicket = 0

    func restartJourney() {
        let ticket = nextJourneyStatusTicket()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await engine.restartJourney()
            setJourneyStatus(status, ticket: ticket)
        }
    }

    /// Advances the cursor and reports where the engine moved it to.
    ///
    /// This is the primitive, because the engine reports the new position only as the answer to the
    /// advance itself. A caller that dispatches the advance and then reads ``journeyStatus`` is
    /// reading the cursor from *before* the command — which is exactly what `mimic journey advance`
    /// used to hand back.
    func advanceJourneyReportingStatus() async -> JourneyStatus? {
        let ticket = nextJourneyStatusTicket()
        let status = await engine.advanceJourney()
        setJourneyStatus(status, ticket: ticket)
        return status
    }

    /// The fire-and-forget form, for the menu item and the run controls: they have nowhere to report
    /// a status to and are passed straight to a `Button` as a `() -> Void` action.
    func advanceJourney() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await advanceJourneyReportingStatus()
        }
    }

    func refreshJourneyStatus() {
        let ticket = nextJourneyStatusTicket()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await engine.journeyStatus()
            setJourneyStatus(status, ticket: ticket)
        }
    }

    /// The engine's cursor, read only once the configuration push dispatched most recently has landed.
    ///
    /// The `async` twin of ``refreshJourneyStatus()``, in the same way
    /// ``advanceJourneyReportingStatus()`` is of ``advanceJourney()`` and for the same reason: a
    /// control call has to answer with what the engine holds *now*, and both the published mirror and
    /// a bare `engine.journeyStatus()` answer with what it held before the command.
    ///
    /// The wait is what makes it correct rather than merely awaited. Activating a journey pushes the
    /// project to the engine from ``updateMocks(endpoints:journey:)``, which dispatches; without
    /// waiting for that task this would reach the engine actor first and report the *previous*
    /// journey. The ticket is taken after the wait, so this write outranks the mirror refresh the push
    /// task issues on its way out — the two read the same engine either way, so it orders them rather
    /// than choosing between them.
    func journeyStatusAfterPendingUpdates() async -> JourneyStatus? {
        await pendingMockUpdate?.value
        let ticket = nextJourneyStatusTicket()
        let status = await engine.journeyStatus()
        setJourneyStatus(status, ticket: ticket)
        return status
    }

    private func nextJourneyStatusTicket() -> Int {
        journeyStatusTicket += 1
        return journeyStatusTicket
    }

    /// Publishes a mirror update, unless something newer was asked for while it was in flight.
    private func setJourneyStatus(_ status: JourneyStatus?, ticket: Int) {
        guard ticket == journeyStatusTicket else { return }
        journeyStatus = status
    }

    private func appendLog(_ entry: RequestLog) {
        requestLogs.append(entry)
        if requestLogs.count > Self.maxRequestLogEntries {
            requestLogs.removeFirst(requestLogs.count - Self.maxRequestLogEntries)
        }
    }
}
