import Vapor
import Domain

/// Embedded mock HTTP server. Owns a Vapor `Application`, a `MockRouteStore` snapshot of the live
/// configuration, and a single `logStream` of request records.
///
/// Logging uses one channel only: every served request is yielded to `logStream`, which a single
/// consumer drains. The stream spans the engine's whole lifetime (it is *not* finished on `stop`),
/// so a stop/start cycle keeps delivering logs to the same consumer.
public actor MockServerEngine {
    private var app: Application?
    private var isStarting = false
    private let routeStore = MockRouteStore()

    /// Single-consumer stream of served request logs. Bounded buffer drops the oldest entries if the
    /// consumer falls behind, so memory stays bounded regardless of request volume.
    public nonisolated let logStream: AsyncStream<RequestLog>
    private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation

    public init() {
        (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream(bufferingPolicy: .bufferingNewest(1000))
    }

    public func start(configuration: ServerConfiguration) async throws {
        guard app == nil, !isStarting else { throw MockServerError.alreadyRunning }
        isStarting = true
        defer { isStarting = false }

        // The route store (endpoints + global delay + journey) is populated via
        // `updateConfiguration`, which the runtime calls when a project is applied — start() must not
        // clobber the already-loaded config.
        let env = Environment(name: "development", arguments: ["vapor"])
        let newApp = try await Application.make(env)
        newApp.logger.logLevel = .warning
        newApp.http.server.configuration.hostname = "127.0.0.1"
        newApp.http.server.configuration.port = configuration.port

        VaporConfigurator.registerRoutes(on: newApp, routeStore: routeStore, logContinuation: logContinuation)

        do {
            try await newApp.server.start(address: .hostname("127.0.0.1", port: configuration.port))
        } catch {
            try await newApp.asyncShutdown()
            throw VaporConfigurator.mapStartError(error, port: configuration.port)
        }

        app = newApp
    }

    public func stop() async throws {
        guard let running = app else { throw MockServerError.notRunning }
        app = nil
        await running.server.shutdown()
        try await running.asyncShutdown()
        // Intentionally does NOT finish `logContinuation` — the engine may be started again and the
        // same consumer must keep receiving logs across stop/start cycles.
    }

    public var isRunning: Bool { app != nil }

    /// Replaces the live configuration. `globalDelayMs` defaults to `0` so direct callers (and the
    /// engine's own tests) can update routes without restating delay.
    public func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int = 0) async {
        await routeStore.update(endpoints: endpoints, globalDelayMs: globalDelayMs)
    }

    /// Replaces the live configuration including the active journey.
    public func updateConfiguration(
        endpoints: [Endpoint],
        globalDelayMs: Int,
        journey: Journey?
    ) async {
        await routeStore.update(endpoints: endpoints, globalDelayMs: globalDelayMs, journey: journey)
    }

    // MARK: - Journey runtime control

    /// Rewinds the active journey. Returns `nil` when no journey is active.
    public func restartJourney() async -> JourneyStatus? {
        await routeStore.restartJourney()
    }

    /// Retires the current step without serving it.
    public func advanceJourney() async -> JourneyStatus? {
        await routeStore.advanceJourney()
    }

    public func journeyStatus() async -> JourneyStatus? {
        await routeStore.journeyStatus()
    }

    deinit {
        logContinuation.finish()
    }
}
