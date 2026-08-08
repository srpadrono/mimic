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
    var requestLogs: [RequestLog] = [] {
        didSet { recountUnmatchedIfReplaced(oldValue) }
    }

    /// How many logged requests nothing answered, maintained incrementally.
    ///
    /// **`WorkspaceView.body` used to compute this by scanning the whole log, twice** — once for the
    /// toolbar and once for the inspector's overview — and that body re-evaluates on *every served
    /// request*, because appending to `requestLogs` invalidates it. At the 1000-entry cap that is two
    /// thousand-element scans per request, for a number that changes by at most one.
    ///
    /// Kept correct across all three ways the log changes: an append (below), an eviction at the cap
    /// (below), and a wholesale replacement — `requestLogs = []` from the Clear button, or a restore.
    /// The last one cannot be tracked incrementally, so `didSet` recounts, which is fine because it
    /// happens when a human presses a button rather than when a request arrives.
    private(set) var unmatchedCount: Int = 0

    /// Recount only when the array was replaced wholesale rather than appended to.
    ///
    /// The cheap discriminator is the count: `appendLog` maintains the tally itself, so if the log
    /// grew by exactly one it has already been accounted for.
    private func recountUnmatchedIfReplaced(_ oldValue: [RequestLog]) {
        guard !isAppending else { return }
        unmatchedCount = requestLogs.count { $0.outcome.isMissingConfiguration }
    }

    /// Set while `appendLog` is mutating, so `didSet` does not undo its incremental bookkeeping with
    /// the O(n) scan this whole property exists to avoid.
    private var isAppending = false
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

    func restartJourney() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            journeyStatus = await engine.restartJourney()
        }
    }

    func advanceJourney() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            journeyStatus = await engine.advanceJourney()
        }
    }

    func refreshJourneyStatus() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            journeyStatus = await engine.journeyStatus()
        }
    }

    private func appendLog(_ entry: RequestLog) {
        isAppending = true
        defer { isAppending = false }

        requestLogs.append(entry)
        if entry.outcome.isMissingConfiguration { unmatchedCount += 1 }

        if requestLogs.count > Self.maxRequestLogEntries {
            let overflow = requestLogs.count - Self.maxRequestLogEntries
            // Decrement for what is evicted, rather than recounting. Past request 1,001 this runs on
            // every single request, so a scan here would be the very thing the counter avoids.
            for evicted in requestLogs.prefix(overflow) where evicted.outcome.isMissingConfiguration {
                unmatchedCount -= 1
            }
            requestLogs.removeFirst(overflow)
        }
    }
}
