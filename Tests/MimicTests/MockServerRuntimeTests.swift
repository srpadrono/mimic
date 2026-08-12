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

    @Test("Port conflicts surface an alert and keep the server stopped")
    func startServerPortConflict() async throws {
        let engine = FakeEngine()
        await engine.setStartError(MockServerError.portInUse(port: 8080))
        let manager = MockServerRuntime(engine: engine)

        manager.startServer()
        try await waitUntil {
            manager.serverState == .stopped && manager.portConflictAlert?.conflictingPort == 8080
        }

        #expect(manager.portConflictAlert?.suggestedPort == 8081)
        #expect(manager.genericStartError == nil)
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
