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
        requestLogs.append(entry)
        if requestLogs.count > Self.maxRequestLogEntries {
            requestLogs.removeFirst(requestLogs.count - Self.maxRequestLogEntries)
        }
    }
}
