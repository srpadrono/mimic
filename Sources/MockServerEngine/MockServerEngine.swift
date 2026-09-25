import Vapor
import Domain

/// Embedded mock HTTP server. Owns a Vapor `Application`, a `MockRouteStore` snapshot of the live
/// configuration, and a single `logStream` of request records.
///
/// Logging uses one channel only: every admitted request with a valid-size, complete body is
/// yielded to `logStream`, which a single consumer drains. Overload, oversized, and timed-out
/// request bodies have no log.
/// The stream spans the engine's whole lifetime (it is *not* finished on `stop`),
/// so a stop/start cycle keeps delivering logs to the same consumer.
public actor MockServerEngine {
    private var apps: [Int: Application] = [:]
    private var isStarting = false
    /// Set for the whole of `stop()`, because `stop()` clears `app` before it awaits the shutdown and
    /// `app == nil` is otherwise indistinguishable from "nothing is listening". See `start`.
    private var isStopping = false
    private let routeStore = MockRouteStore()
    /// Assigned before each configuration call awaits the route store. Actor reentrancy can change
    /// delivery order; the store uses this revision to keep the newest request-facing settings.
    private var configurationRevision = 0

    private func nextConfigurationRevision() -> Int {
        configurationRevision += 1
        return configurationRevision
    }

    /// Lossless delivery to the single consumer. Automatic response capture consumes this stream,
    /// so dropping pending events also silently loses persistent mocks. Producers reserve one of
    /// 32 handler permits and one of 64 pending-log permits before resolving a route. Excess requests get a 503 without
    /// advancing a journey; the runtime returns permits after processing accepted entries.
    public nonisolated let logStream: AsyncStream<RequestLog>
    private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation
    nonisolated let logGate: RequestLogGate

    public init() {
        let gate = RequestLogGate()
        let (stream, continuation) = AsyncStream<RequestLog>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { _ in
            Task { await gate.terminate() }
        }
        logGate = gate
        logStream = stream
        logContinuation = continuation
    }

    /// Called once for each log after its consumer has handled automatic capture and UI retention.
    public nonisolated func acknowledgeLog() async {
        await logGate.acknowledge()
    }

    public func start(configuration: ServerConfiguration) async throws {
        guard apps.isEmpty, !isStarting else { throw MockServerError.alreadyRunning }
        // A stop in flight is invisible to the guard above: `stop()` sets `app = nil` and only then
        // suspends on `server.shutdown()`, and an actor admits another call at that suspension — so a
        // start arriving in that window sees `nil`, passes, and binds a port the outgoing application
        // has not released. Reported as `.invalidState(.stopping)` rather than `.alreadyRunning`
        // because the two ask different things of the caller: one means "you already have a server",
        // this one means "ask again in a moment".
        guard !isStopping else { throw MockServerError.invalidState(.stopping) }
        isStarting = true
        defer { isStarting = false }

        let revision = nextConfigurationRevision()
        await routeStore.updateServerConfiguration(configuration, revision: revision)
        let listeners = configuration.listeners.map { ($0.port, $0.id == ServerConfiguration.primaryID ? nil : Optional($0.id)) }
        let localPorts = Set(listeners.map(\.0))
        guard localPorts.count == listeners.count else {
            throw MockServerError.invalidConfiguration("Each backend must use a different local port.")
        }
        var started: [Int: Application] = [:]
        do {
            for (port, backendID) in listeners {
                let env = Environment(name: "development", arguments: ["vapor"])
                let newApp = try await Application.make(env)
                newApp.logger.logLevel = .warning
                newApp.http.client.configuration.redirectConfiguration = .disallow
                newApp.http.client.configuration.decompression = .disabled
                newApp.http.client.configuration.timeout = .init(connect: .seconds(10), read: .seconds(30))
                newApp.http.server.configuration.hostname = "127.0.0.1"
                newApp.http.server.configuration.port = port
                VaporConfigurator.registerRoutes(
                    on: newApp, routeStore: routeStore, logContinuation: logContinuation, logGate: logGate,
                    backendID: backendID, listenerPort: port, localPorts: localPorts
                )
                do {
                    try await newApp.server.start(address: .hostname("127.0.0.1", port: port))
                } catch {
                    try await newApp.asyncShutdown()
                    throw VaporConfigurator.mapStartError(error, port: port)
                }
                started[port] = newApp
            }
            apps = started
        } catch {
            for running in started.values {
                await running.server.shutdown()
                try? await running.asyncShutdown()
            }
            throw error
        }
    }

    /// Updates listener settings without changing the project attached to live routes.
    public func updateServerConfiguration(_ configuration: ServerConfiguration) async {
        let revision = nextConfigurationRevision()
        await routeStore.updateServerConfiguration(configuration, revision: revision)
    }

    /// Updates listener settings and explicitly selects or clears the active project.
    public func updateServerConfiguration(_ configuration: ServerConfiguration, projectID: UUID?) async {
        let revision = nextConfigurationRevision()
        await routeStore.updateServerConfiguration(configuration, projectID: projectID, revision: revision)
    }

    /// Installs the server settings, project attribution, routes, and journey as one live snapshot.
    /// A request cannot resolve against fields from two different project pushes.
    public func updateConfiguration(
        configuration: ServerConfiguration,
        projectID: UUID?,
        endpoints: [Endpoint],
        journey: Journey?,
        activationEpoch: Int
    ) async {
        let revision = nextConfigurationRevision()
        await routeStore.update(
            configuration: configuration,
            projectID: projectID,
            endpoints: endpoints,
            journey: journey,
            activationEpoch: activationEpoch,
            revision: revision
        )
    }

    public func stop() async throws {
        guard !apps.isEmpty else { throw MockServerError.notRunning }
        // Both assignments happen before the first suspension, so no other call can observe the
        // half-stopped state: `app` already cleared, the socket still open.
        isStopping = true
        let running = apps
        apps = [:]
        defer { isStopping = false }
        for app in running.values { await app.server.shutdown() }
        for app in running.values { try await app.asyncShutdown() }
        // Intentionally does NOT finish `logContinuation` — the engine may be started again and the
        // same consumer must keep receiving logs across stop/start cycles.
    }

    public var isRunning: Bool { !apps.isEmpty }

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
    /// **The production caller is `MockServerRuntime.updateMocks`**, which passes the count
    /// `AppState.activateJourney(id:)` bumps. `grep -rn activationEpoch --include='*.swift' Sources`
    /// is the check, and it has to keep finding a hit in `MockServerRuntime.swift` and
    /// `AppState.swift`: if the only hits left are in this module, an activation has stopped being
    /// distinguishable from an edit again and `mimic journey activate` against the already-active
    /// journey silently resumes mid-run.
    ///
    /// The three-argument overload above passes `nil` and is the right call for anything that is not
    /// an activation.
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
