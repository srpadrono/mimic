import Foundation
import Testing
import Domain
import MockServerEngine
@testable import AppFeatures

@Suite("MockServerRuntime Tests")
@MainActor
struct MockServerRuntimeTests {
    actor FakeEngine: MockServerEngineProtocol {
        enum EngineFailure: Error, LocalizedError {
            case generic(String)

            var errorDescription: String? {
                switch self {
                case .generic(let message): message
                }
            }
        }

        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation

        private(set) var startConfigurations: [ServerConfiguration] = []
        private(set) var stopCallCount = 0
        private(set) var updatedEndpoints: [[Endpoint]] = []
        private(set) var updatedJourneys: [Journey?] = []
        private(set) var restartCallCount = 0
        private(set) var advanceCallCount = 0
        var startError: Error?
        var stopError: Error?
        var stubbedJourneyStatus: JourneyStatus?

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func start(configuration: ServerConfiguration) async throws {
            startConfigurations.append(configuration)
            if let startError {
                throw startError
            }
        }

        func stop() async throws {
            stopCallCount += 1
            if let stopError {
                throw stopError
            }
        }

        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {
            updatedEndpoints.append(endpoints)
            updatedJourneys.append(nil)
        }

        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int, journey: Journey?) async {
            updatedEndpoints.append(endpoints)
            updatedJourneys.append(journey)
        }

        func restartJourney() async -> JourneyStatus? {
            restartCallCount += 1
            return stubbedJourneyStatus
        }

        func advanceJourney() async -> JourneyStatus? {
            advanceCallCount += 1
            return stubbedJourneyStatus
        }

        func journeyStatus() async -> JourneyStatus? {
            stubbedJourneyStatus
        }

        func setStubbedJourneyStatus(_ status: JourneyStatus?) {
            stubbedJourneyStatus = status
        }

        nonisolated func emit(_ log: RequestLog) {
            logContinuation.yield(log)
        }
    }

    /// An engine whose `journeyStatus()` does not answer until it is released.
    ///
    /// That is the whole fixture: it lets a mirror update that was *requested first* come back
    /// *last*, which is the ordering `MockServerRuntime`'s ticket exists to survive and the ordering
    /// no arrangement of `FakeEngine` can produce, because every one of its answers is immediate.
    actor GatedEngine: MockServerEngineProtocol {
        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation

        private var isReleased = false
        /// Incremented once a gated `journeyStatus()` has actually answered, so a test can wait for
        /// the superseded write to have been *attempted* rather than sleeping and hoping.
        private(set) var completedStatusCalls = 0
        private var statusAnswer: JourneyStatus?
        private var restartAnswer: JourneyStatus?

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func start(configuration: ServerConfiguration) async throws {}
        func stop() async throws {}
        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {}

        func setAnswers(status: JourneyStatus?, restart: JourneyStatus?) {
            statusAnswer = status
            restartAnswer = restart
        }

        func release() {
            isReleased = true
        }

        func journeyStatus() async -> JourneyStatus? {
            // Sleeping rather than spinning: each suspension hands the actor back, so `restartJourney`
            // below is admitted and answers while this call is still parked.
            while !isReleased {
                try? await Task.sleep(for: .milliseconds(5))
            }
            completedStatusCalls += 1
            return statusAnswer
        }

        func restartJourney() async -> JourneyStatus? { restartAnswer }
        func advanceJourney() async -> JourneyStatus? { restartAnswer }
    }

    /// An engine whose `start` does not return until it is released.
    ///
    /// The interval between `MockServerRuntime.startServer()` publishing `.starting` and the engine
    /// binding is the whole subject of ``configuringDuringABindCannotChangeThePublishedPort``, and
    /// without a gate its width is the scheduler's business rather than the test's. Sleeping rather
    /// than spinning, so the actor is handed back on every suspension and `startConfigurations` stays
    /// readable while a start is parked here — the same shape ``GatedEngine`` above uses to park a
    /// journey-status read.
    actor GatedStartEngine: MockServerEngineProtocol {
        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation

        private(set) var startConfigurations: [ServerConfiguration] = []
        private var isHoldingStart = true

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func release() { isHoldingStart = false }

        func start(configuration: ServerConfiguration) async throws {
            startConfigurations.append(configuration)
            while isHoldingStart {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        func stop() async throws {}
        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {}
    }

    /// An engine that reports a journey cursor only for a journey it has actually been handed.
    ///
    /// That is what makes it a witness for the ordering rather than a stub: a status read that
    /// overtook the push it was supposed to follow finds nothing here, instead of finding an answer
    /// that happens to look right.
    actor PushRecordingEngine: MockServerEngineProtocol {
        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation
        private var pushed: Journey?

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func start(configuration: ServerConfiguration) async throws {}
        func stop() async throws {}
        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {}

        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int, journey: Journey?) async {
            pushed = journey
        }

        func journeyStatus() async -> JourneyStatus? {
            guard let pushed else { return nil }
            return JourneyStatus.make(journey: pushed, state: nil)
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(20),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(for: interval)
        }
        Issue.record("Timed out waiting for condition")
    }

    /// The same poll for a predicate that has to ask an actor. Named apart from `waitUntil` rather
    /// than overloaded on the closure's effects, which is the shape that resolves to whichever
    /// overload the compiler happens to prefer.
    private func waitUntilAsync(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(20),
        _ predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() {
                return
            }
            try await Task.sleep(for: interval)
        }
        Issue.record("Timed out waiting for condition")
    }

    private func makeEndpoint(name: String = "Users") -> Endpoint {
        let scenario = Scenario(name: "Default", statusCode: 200, body: #"{"ok":true}"#)
        return Endpoint(
            name: name,
            method: .get,
            path: "/api/\(name.lowercased())",
            scenarios: [scenario],
            activeScenarioID: scenario.id
        )
    }

    @Test("Start server succeeds and records the configuration")
    func startServerSucceeds() async throws {
        let engine = FakeEngine()
        let manager = MockServerRuntime(engine: engine)
        manager.serverConfiguration = ServerConfiguration(port: 9999, globalDelayMs: 120)

        manager.startServer()
        try await waitUntil {
            if case .running(let port) = manager.serverState {
                return port == 9999
            }
            return false
        }

        let startConfigurations = await engine.startConfigurations
        #expect(startConfigurations.count == 1)
        #expect(startConfigurations.first?.port == 9999)
        #expect(startConfigurations.first?.globalDelayMs == 120)
    }

    /// The read-then-read across the bind, driven.
    ///
    /// `serverConfiguration` is a mutable property here and `.serverConfigure` is *project*-scoped, so
    /// `AppControlHost` applies it with no lifecycle guard at all — `mimic server start` followed by
    /// `mimic server configure --port 9000` lands here while the engine is still binding.
    /// `startServer()` used to read the property twice, once on either side of `await engine.start`:
    /// it bound the port the first read carried and published the port the second one did, so a script
    /// was handed a `baseURL` nothing was listening on.
    ///
    /// The gate is what makes this a claim rather than a coincidence. Without it the bind usually
    /// completes before the reconfigure lands, and the assertion passes against the broken version.
    @Test("A configure arriving mid-bind cannot change the port the runtime publishes")
    func configuringDuringABindCannotChangeThePublishedPort() async throws {
        let engine = GatedStartEngine()
        let manager = MockServerRuntime(engine: engine)
        manager.serverConfiguration = ServerConfiguration(port: 8080, globalDelayMs: 0)

        manager.startServer()
        // Parked inside `engine.start`, which is the state the reconfigure has to arrive in.
        try await waitUntilAsync { await engine.startConfigurations.count == 1 }
        #expect(manager.serverState == .starting)

        manager.serverConfiguration = ServerConfiguration(port: 9000, globalDelayMs: 0)
        await engine.release()

        try await waitUntil { manager.serverState.runningPort != nil }
        #expect(
            manager.serverState == .running(port: 8080),
            "the runtime published the reconfigured port for a listener bound to the old one"
        )
        let boundPorts = await engine.startConfigurations.map(\.port)
        #expect(boundPorts == [8080])
    }

    /// A port conflict is a *failure*, not a stop.
    ///
    /// It used to publish `.stopped`, which is indistinguishable from a server nobody started, and the
    /// only other trace was `portConflictAlert` — which nothing outside `WorkspaceView` reads and a
    /// headless run never renders. `AppControlHost.serverStart` has already answered by the time the
    /// bind fails, so the state and `startFailure` are the whole of what a later `mimic server status`
    /// has to report from.
    @Test("A port conflict is an error state carrying the code a script branches on")
    func startServerPortConflict() async throws {
        let engine = FakeEngine()
        await engine.setStartError(MockServerError.portInUse(port: 8080))
        let manager = MockServerRuntime(engine: engine)

        manager.startServer()
        try await waitUntil { manager.serverState.isError }

        // The engine's own sentence, verbatim — `server status` reports the engine's diagnosis
        // rather than a paraphrase of it.
        #expect(manager.serverState == .error("Port 8080 is already in use."))
        #expect(manager.startFailure?.code == "server.portInUse")
        #expect(manager.startFailure?.details?["port"] == "8080")
        // The window's alert is unchanged: it is what offers the next port.
        #expect(manager.portConflictAlert?.conflictingPort == 8080)
        #expect(manager.portConflictAlert?.suggestedPort == 8081)
        #expect(manager.genericStartError == nil)
    }

    /// A start that succeeds clears whatever the previous one failed with, so a stale code cannot be
    /// reported next to a running server.
    @Test("A retry after a conflict clears the recorded failure")
    func retryClearsTheRecordedStartFailure() async throws {
        let engine = FakeEngine()
        await engine.setStartError(MockServerError.portInUse(port: 8080))
        let manager = MockServerRuntime(engine: engine)

        manager.startServer()
        try await waitUntil { manager.startFailure != nil }

        await engine.setStartError(nil)
        manager.retryStartOnNextPort(from: 8080)
        try await waitUntil { manager.serverState.runningPort == 8081 }

        #expect(manager.startFailure == nil)
        #expect(manager.portConflictAlert == nil)
    }

    @Test("Generic start failures set error state and message")
    func startServerGenericFailure() async throws {
        let engine = FakeEngine()
        await engine.setStartError(FakeEngine.EngineFailure.generic("Start failed"))
        let manager = MockServerRuntime(engine: engine)

        manager.startServer()
        try await waitUntil {
            if case .error(let message) = manager.serverState {
                return message == "Start failed"
            }
            return false
        }

        #expect(manager.genericStartError == "Start failed")
        #expect(manager.portConflictAlert == nil)
    }

    @Test("Stop server transitions back to stopped even if engine stop throws")
    func stopServerAlwaysStops() async throws {
        let engine = FakeEngine()
        await engine.setStopError(FakeEngine.EngineFailure.generic("Stop failed"))
        let manager = MockServerRuntime(engine: engine)
        manager.serverState = .running(port: 8080)

        manager.stopServer()
        try await waitUntil {
            manager.serverState == .stopped
        }

        #expect(await engine.stopCallCount == 1)
    }

    @Test("Retry start increments port clears alert and restarts")
    func retryStartUsesNextPort() async throws {
        let engine = FakeEngine()
        let manager = MockServerRuntime(engine: engine)
        manager.portConflictAlert = PortConflictAlertData(conflictingPort: 8080)

        manager.retryStartOnNextPort(from: 8080)
        try await waitUntil {
            if case .running(let port) = manager.serverState {
                return port == 8081
            }
            return false
        }

        #expect(manager.serverConfiguration.port == 8081)
        #expect(manager.portConflictAlert == nil)
        #expect(await engine.startConfigurations.last?.port == 8081)
    }

    @Test("Update mocks forwards endpoint lists to the engine")
    func updateMocksForwardsEndpoints() async throws {
        let engine = FakeEngine()
        let manager = MockServerRuntime(engine: engine)
        let endpoints = [makeEndpoint(name: "Users"), makeEndpoint(name: "Posts")]

        manager.updateMocks(endpoints: endpoints)
        // Polled rather than slept: `updateMocks` dispatches, so a flat 50 ms was both a floor every
        // run paid and a ceiling that would fail on a loaded machine.
        try await waitUntilAsync { await engine.updatedEndpoints.isEmpty == false }
        let updatedEndpoints = await engine.updatedEndpoints
        #expect(updatedEndpoints.count == 1)
        #expect(updatedEndpoints.first?.map(\.name) == ["Users", "Posts"])
    }

    /// Every mirror update reaches the engine across an `await`, and each used to do so from an
    /// unstructured `Task` with no ordering between them — while the drain loop starts one per served
    /// request. So under a burst the answers landed in whatever order the engine handed them back,
    /// and the *last* write could be the *oldest* read: the mirror settled on a stale cursor and
    /// stayed there until the next request happened to refresh it.
    ///
    /// The gate makes that ordering happen on purpose rather than under load. Both tickets are taken
    /// synchronously on the main actor, in call order, so the refresh is unambiguously the older
    /// request; the gate then makes it the later *answer*.
    @Test("A superseded mirror update cannot overwrite the newer one that already landed")
    func aStaleJourneyStatusIsDropped() async throws {
        let engine = GatedEngine()
        let stale = JourneyStatus.make(journey: Journey(name: "Stale"), state: nil)
        let fresh = JourneyStatus.make(journey: Journey(name: "Fresh"), state: nil)
        await engine.setAnswers(status: stale, restart: fresh)

        let manager = MockServerRuntime(engine: engine)

        manager.refreshJourneyStatus()   // ticket 1 — parked in the engine until released
        manager.restartJourney()         // ticket 2 — answers immediately

        try await waitUntil { manager.journeyStatus?.journeyName == "Fresh" }

        await engine.release()
        // Wait for the older read to have actually come back, so what follows is an assertion about
        // a write that was *attempted and dropped* rather than one that had not arrived yet.
        try await waitUntilAsync { await engine.completedStatusCalls == 1 }
        // Then a short settle: the runtime hops back to the main actor to publish, so the engine
        // having answered is one step short of the write having been offered. This is the one wait
        // here that cannot be a poll — the condition being asserted is that nothing happens.
        try await Task.sleep(for: .milliseconds(100))

        #expect(
            manager.journeyStatus?.journeyName == "Fresh",
            "the superseded refresh republished a cursor the restart had already replaced"
        )
    }

    /// The engine's cursor is only readable once the push that put the journey there has landed.
    ///
    /// `updateMocks` reaches the engine from an unstructured task. A status read issued straight after
    /// it hops to the engine actor from the *currently running* task — so its job is enqueued on that
    /// actor before the push task has even been scheduled — and answers about the configuration the
    /// engine still had. That ordering is deterministic rather than lucky, which is why this test needs
    /// no gate: `PushRecordingEngine` reports nothing at all until a journey has reached it, so a read
    /// that overtook the push comes back `nil`.
    @Test("The awaited journey status waits for the push that preceded it")
    func awaitedJourneyStatusWaitsForThePush() async throws {
        let engine = PushRecordingEngine()
        let manager = MockServerRuntime(engine: engine)

        manager.updateMocks(endpoints: [], journey: Journey(name: "Flow"))
        let status = await manager.journeyStatusAfterPendingUpdates()

        #expect(
            status?.journeyName == "Flow",
            "the status was read before the push that loaded the journey reached the engine"
        )
        // …and the mirror the window reads settles on the same answer rather than on the superseded
        // refresh the push task issues on its way out.
        #expect(manager.journeyStatus?.journeyName == "Flow")
    }

    @Test("Request logs are appended and capped at the maximum")
    func requestLogsAreTrimmedToMaximum() async throws {
        let engine = FakeEngine()
        let manager = MockServerRuntime(engine: engine)

        for index in 0..<(MockServerRuntime.maxRequestLogEntries + 5) {
            engine.emit(
                RequestLog(
                    method: .get,
                    path: "/logs/\(index)",
                    responseStatusCode: 200
                )
            )
        }

        // Wait for the *last* emission, not for the count.
        //
        // `count == maxRequestLogEntries` becomes true on the thousandth delivery and stays true
        // forever after, so it says nothing about whether the final four have arrived. Emission is
        // asynchronous, so the wait returned early and the assertions ran against a buffer holding
        // `/logs/2 … /logs/1001` — the test failed roughly one run in three, three entries short,
        // and read like a bug in the rotating buffer rather than in its own predicate.
        let lastPath = "/logs/\(MockServerRuntime.maxRequestLogEntries + 4)"
        try await waitUntil { manager.requestLogs.last?.path == lastPath }

        #expect(manager.requestLogs.count == MockServerRuntime.maxRequestLogEntries)
        #expect(manager.requestLogs.first?.path == "/logs/5")
        #expect(manager.requestLogs.last?.path == lastPath)
    }
}

private extension MockServerRuntimeTests.FakeEngine {
    func setStartError(_ error: Error?) async {
        startError = error
    }

    func setStopError(_ error: Error?) async {
        stopError = error
    }
}
