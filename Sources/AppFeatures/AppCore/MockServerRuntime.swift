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
    func startServer() {
        guard serverState == .stopped || serverState.isError else { return }
        serverState = .starting

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await engine.start(configuration: serverConfiguration)
                serverState = .running(port: serverConfiguration.port)
            } catch MockServerError.portInUse(let port) {
                serverState = .stopped
                portConflictAlert = PortConflictAlertData(conflictingPort: port)
            } catch {
                serverState = .error(error.localizedDescription)
                genericStartError = error.localizedDescription
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

    func updateMocks(endpoints: [Endpoint], journey: Journey? = nil) {
        let globalDelayMs = serverConfiguration.globalDelayMs
        Task { @MainActor [weak self] in
            guard let self else { return }
            await engine.updateConfiguration(
                endpoints: endpoints,
                globalDelayMs: globalDelayMs,
                journey: journey
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
