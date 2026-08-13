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
    /// Set for the whole of `stop()`, because `stop()` clears `app` before it awaits the shutdown and
    /// `app == nil` is otherwise indistinguishable from "nothing is listening". See `start`.
    private var isStopping = false
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
        // A stop in flight is invisible to the guard above: `stop()` sets `app = nil` and only then
        // suspends on `server.shutdown()`, and an actor admits another call at that suspension — so a
        // start arriving in that window sees `nil`, passes, and binds a port the outgoing application
        // has not released. Reported as `.invalidState(.stopping)` rather than `.alreadyRunning`
        // because the two ask different things of the caller: one means "you already have a server",
        // this one means "ask again in a moment".
        guard !isStopping else { throw MockServerError.invalidState(.stopping) }
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
        // Both assignments happen before the first suspension, so no other call can observe the
        // half-stopped state: `app` already cleared, the socket still open.
        isStopping = true
        app = nil
        defer { isStopping = false }
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

    /// Replaces the live configuration including the active journey, without claiming the push is an
    /// activation. A run already in progress on the same journey with the same steps survives it.
    ///
    /// Kept as its own entry point beside the overload below rather than folded into it with a
    /// default argument, because a default argument does not satisfy a protocol requirement and this
    /// exact signature is one: `MockServerEngineProtocol` in `AppFeatures` declares it, and
    /// `extension MockServerEngine: MockServerEngineProtocol {}` is what conforms.
    public func updateConfiguration(
        endpoints: [Endpoint],
        globalDelayMs: Int,
        journey: Journey?
    ) async {
        await routeStore.update(
            endpoints: endpoints,
            globalDelayMs: globalDelayMs,
            journey: journey,
            activationEpoch: nil
        )
    }

    /// Replaces the live configuration and says which activation the push belongs to.
    ///
    /// `activationEpoch` is the caller's running count of the journey activations it has performed.
    /// A push carrying a higher count than any this engine has seen resets the journey run even when
    /// the journey is unchanged — re-activating the journey that is already active is otherwise
    /// indistinguishable from re-sending the same project, and the two have to behave differently.
    /// See ``MockRouteStore/update(endpoints:globalDelayMs:journey:activationEpoch:)`` for why it is
    /// a count rather than a flag.
    ///
    /// **Nothing outside this module calls it yet**, so `mimic journey activate` against the journey
    /// already active still does not restart the run — the engine can now be told, and no host tells
    /// it. `grep -rn activationEpoch --include='*.swift' Sources Tests` is the check; every hit is in
    /// `MockServerEngine` or its own tests until `MockServerRuntime.updateMocks` and
    /// `MimicControlService.pushConfigurationToEngine` pass a count they keep.
    public func updateConfiguration(
        endpoints: [Endpoint],
        globalDelayMs: Int,
        journey: Journey?,
        activationEpoch: Int
    ) async {
        await routeStore.update(
            endpoints: endpoints,
            globalDelayMs: globalDelayMs,
            journey: journey,
            activationEpoch: activationEpoch
        )
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
