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
        try await Task.sleep(for: .milliseconds(50))
        let updatedEndpoints = await engine.updatedEndpoints
        #expect(updatedEndpoints.count == 1)
        #expect(updatedEndpoints.first?.map(\.name) == ["Users", "Posts"])
    }

    // MARK: - The unmatched tally

    @Test("Unmatched count tracks appends without rescanning the log")
    func unmatchedCountTracksAppends() async throws {
        let engine = FakeEngine()
        let manager = MockServerRuntime(engine: engine)

        engine.emit(RequestLog(method: .get, path: "/a", responseStatusCode: 200, outcome: .endpoint))
        engine.emit(RequestLog(method: .get, path: "/b", responseStatusCode: 404, outcome: .unmatched))
        engine.emit(RequestLog(method: .get, path: "/c", responseStatusCode: 404, outcome: .unmatched))

        try await waitUntil { manager.requestLogs.last?.path == "/c" }

        #expect(manager.unmatchedCount == 2)
        // The tally and a full scan must agree. This is the assertion that actually protects the
        // optimisation: it is the O(n) answer the view used to compute inline.
        #expect(manager.unmatchedCount == manager.requestLogs.count { $0.outcome.isMissingConfiguration })
    }

    @Test("Unmatched count decrements as entries are evicted at the cap")
    func unmatchedCountFollowsEviction() async throws {
        let engine = FakeEngine()
        let manager = MockServerRuntime(engine: engine)

        // Every entry unmatched, so eviction is guaranteed to drop unmatched ones. If the counter
        // only ever incremented, it would read `max + 5` here while the log holds `max`.
        for index in 0..<(MockServerRuntime.maxRequestLogEntries + 5) {
            engine.emit(
                RequestLog(method: .get, path: "/miss/\(index)", responseStatusCode: 404, outcome: .unmatched)
            )
        }

        let lastPath = "/miss/\(MockServerRuntime.maxRequestLogEntries + 4)"
        try await waitUntil { manager.requestLogs.last?.path == lastPath }

        #expect(manager.unmatchedCount == MockServerRuntime.maxRequestLogEntries)
        #expect(manager.unmatchedCount == manager.requestLogs.count { $0.outcome.isMissingConfiguration })
    }

    @Test("Clearing the log resets the unmatched count")
    func unmatchedCountResetsOnClear() async throws {
        let engine = FakeEngine()
        let manager = MockServerRuntime(engine: engine)

        engine.emit(RequestLog(method: .get, path: "/x", responseStatusCode: 404, outcome: .unmatched))
        try await waitUntil { manager.unmatchedCount == 1 }

        // The Clear button's path: a wholesale replacement, which no incremental bookkeeping can
        // follow, so `didSet` recounts. A counter that only tracked appends would stay at 1 with an
        // empty log, and the toolbar would show a badge for traffic that is no longer there.
        manager.requestLogs = []
        #expect(manager.unmatchedCount == 0)

        // And a restore, the other wholesale write.
        manager.requestLogs = [
            RequestLog(method: .get, path: "/y", responseStatusCode: 404, outcome: .unmatched),
            RequestLog(method: .get, path: "/z", responseStatusCode: 200, outcome: .endpoint)
        ]
        #expect(manager.unmatchedCount == 1)
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
