import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in FoundationNetworking on Linux, not Foundation. Without this the CLI and the
// tests that speak HTTP do not compile there — and CI runs on Linux.
import FoundationNetworking
#endif
import Testing
@testable import Domain
@testable import MockServerEngine

/// These drive the *real* embedded server over *real* HTTP. Unit tests already prove journey
/// resolution is correct; what these prove is that the correct answer actually reaches a client —
/// including the two cases a status code cannot express.
///
/// Time-limited because every case here binds a real socket: a bind that never completes, or a
/// wait on traffic that never arrives, otherwise hangs the whole run with no indication of which
/// test is stuck. A minute is the finest granularity `.timeLimit` offers and is far above what
/// any of these needs — the point is a bound, not a deadline.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct JourneyServingTests {

    // MARK: - Harness

    /// Ports come from the OS rather than being hard-coded — a fixed port makes a suite that fails
    /// only on someone else's machine.
    static func freePort() throws -> Int {
        try #require(PlatformSocket.freePort())
    }

    /// Runs `body` against a started engine on a free port, guaranteeing shutdown.
    static func withEngine(
        endpoints: [Endpoint] = [],
        journey: Journey? = nil,
        globalDelayMs: Int = 0,
        _ body: (MockServerEngine, URL) async throws -> Void
    ) async throws {
        let port = try freePort()
        let engine = MockServerEngine()
        await engine.updateConfiguration(endpoints: endpoints, globalDelayMs: globalDelayMs, journey: journey)
        try await engine.start(configuration: ServerConfiguration(port: port, globalDelayMs: globalDelayMs))
        defer { Task { try? await engine.stop() } }

        let baseURL = try #require(URL(string: "http://127.0.0.1:\(port)"))
        try await body(engine, baseURL)
        try await engine.stop()
    }

    static func session(timeout: TimeInterval = 10) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }

    struct Reply {
        let status: Int
        let body: String
        let headers: [String: String]
    }

    static func call(
        _ method: String,
        _ path: String,
        baseURL: URL,
        session: URLSession
    ) async throws -> Reply {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return Reply(status: http.statusCode, body: String(decoding: data, as: UTF8.self), headers: headers)
    }

    static func endpoint(_ method: HTTPMethod, _ path: String, _ status: Int, body: String = "from-endpoint") -> Endpoint {
        let scenario = Scenario(name: "Default", statusCode: status, body: body)
        return Endpoint(
            name: "\(method.rawValue) \(path)",
            method: method,
            path: path,
            scenarios: [scenario],
            activeScenarioID: scenario.id
        )
    }

    static func journeyFromTemplate(_ id: String, name: String = "Journey") throws -> Journey {
        var project = MockProject(name: "Test")
        _ = try ProjectCommandExecutor.apply(.journeyAddTemplate(templateID: id, name: name), to: &project)
        return try #require(project.journeys.first)
    }

    // MARK: - The canonical flow, over HTTP

    @Test("The journey from the product goal serves the right response to each real request")
    func canonicalJourneyOverHTTP() async throws {
        let journey = try Self.journeyFromTemplate("retry-after-failure")

        try await Self.withEngine(journey: journey) { _, baseURL in
            let session = Self.session()
            let login = try await Self.call("POST", "login", baseURL: baseURL, session: session)
            let firstSummary = try await Self.call("GET", "account-summary", baseURL: baseURL, session: session)
            let inbox = try await Self.call("GET", "inbox", baseURL: baseURL, session: session)
            let secondSummary = try await Self.call("GET", "account-summary", baseURL: baseURL, session: session)

            let statuses: [Int] = [login.status, firstSummary.status, inbox.status, secondSummary.status]
            #expect(statuses == [200, 500, 200, 200])
            #expect(login.body.contains("mimic-session-token"))
            #expect(firstSummary.body.contains("Summary service unavailable"))
            #expect(secondSummary.body.contains("1520.44"))
        }
    }

    @Test("Requests the journey does not script fall through to the endpoints")
    func fallThroughOverHTTP() async throws {
        let journey = Journey(
            name: "Partial",
            steps: [
                JourneyStep(
                    name: "summary fails",
                    method: .get,
                    path: "/account-summary",
                    outcome: .respond(JourneyResponse(statusCode: 503))
                )
            ]
        )

        try await Self.withEngine(
            endpoints: [Self.endpoint(.get, "/settings", 200, body: "settings-payload")],
            journey: journey
        ) { _, baseURL in
            let session = Self.session()
            let settings = try await Self.call("GET", "settings", baseURL: baseURL, session: session)
            #expect(settings.status == 200)
            #expect(settings.body == "settings-payload")

            let summary = try await Self.call("GET", "account-summary", baseURL: baseURL, session: session)
            #expect(summary.status == 503)
        }
    }

    @Test("With no journey active the server behaves exactly as before")
    func endpointOnlyServingIsUnchanged() async throws {
        try await Self.withEngine(endpoints: [Self.endpoint(.get, "/inbox", 201, body: "ok")]) { _, baseURL in
            let session = Self.session()
            let reply = try await Self.call("GET", "inbox", baseURL: baseURL, session: session)
            #expect(reply.status == 201)
            #expect(reply.body == "ok")

            let missing = try await Self.call("GET", "nothing-here", baseURL: baseURL, session: session)
            #expect(missing.status == 404)
        }
    }

    // MARK: - Transport failures

    @Test("A connection-drop step tears the connection down instead of answering")
    func connectionDropTruncatesTheResponse() async throws {
        let journey = Journey(
            name: "Offline",
            steps: [
                JourneyStep(name: "drop", method: .get, path: "/inbox", outcome: .networkFailure(.connectionDrop)),
                JourneyStep(name: "ok", method: .get, path: "/inbox", outcome: .respond(JourneyResponse(statusCode: 200, body: "back"))),
            ]
        )

        try await Self.withEngine(journey: journey) { _, baseURL in
            let port = try #require(baseURL.port)

            // One request, observed raw: the server closes without completing the message.
            let dropped = try RawHTTPClient.send(method: "GET", path: "/inbox", port: port)
            #expect(dropped.isTruncated, "expected an abandoned response, got: \(dropped.raw)")
            #expect(dropped.raw.contains("back") == false, "the scripted body must not leak out")

            // The journey advanced, so recovery is testable — exactly one request was consumed.
            let recovered = try RawHTTPClient.send(method: "GET", path: "/inbox", port: port)
            #expect(recovered.isTruncated == false)
            #expect(recovered.statusLine.contains("200"))
            #expect(recovered.raw.contains("back"))
        }
    }

    @Test("A drop also fails a client that retries, when the step is set to repeat")
    func repeatedDropSurvivesClientRetries() async throws {
        // URLSession retries a failed idempotent request, and each attempt is a separate request as
        // far as the journey is concerned. `repeatCount` is how a drop is made to stick.
        let journey = Journey(
            name: "Really offline",
            steps: [
                JourneyStep(
                    name: "drop",
                    method: .get,
                    path: "/inbox",
                    outcome: .networkFailure(.connectionDrop),
                    repeatCount: 8
                )
            ]
        )

        try await Self.withEngine(journey: journey) { _, baseURL in
            let session = Self.session(timeout: 5)
            await #expect(throws: (any Error).self) {
                _ = try await Self.call("GET", "inbox", baseURL: baseURL, session: session)
            }
        }
    }

    @Test("A timeout step sends nothing at all, so the client's own timeout is what fires")
    func timeoutStepStaysSilent() async throws {
        let journey = Journey(
            name: "Stall",
            steps: [
                JourneyStep(
                    name: "hang",
                    method: .get,
                    path: "/inbox",
                    // Far longer than the read deadline below: the client must give up first.
                    outcome: .networkFailure(.timeout(holdMs: 20_000))
                )
            ]
        )

        try await Self.withEngine(journey: journey) { _, baseURL in
            let port = try #require(baseURL.port)
            let started = Date()
            let stalled = try RawHTTPClient.send(method: "GET", path: "/inbox", port: port, timeout: 1.5)
            let elapsed = Date().timeIntervalSince(started)

            #expect(stalled.isEmpty, "a timeout must send nothing, got: \(stalled.raw)")
            #expect(elapsed >= 1.0, "the request must actually stall, not fail instantly")
            #expect(elapsed < 10.0, "the read deadline must be what ends it")
        }
    }

    @Test("A timeout surfaces to a normal HTTP client as a request timeout")
    func timeoutStepTimesOutURLSession() async throws {
        let journey = Journey(
            name: "Stall",
            steps: [
                JourneyStep(
                    name: "hang",
                    method: .get,
                    path: "/inbox",
                    outcome: .networkFailure(.timeout(holdMs: 20_000)),
                    repeatCount: 4
                )
            ]
        )

        try await Self.withEngine(journey: journey) { _, baseURL in
            let session = Self.session(timeout: 1.5)
            await #expect(throws: (any Error).self) {
                _ = try await Self.call("GET", "inbox", baseURL: baseURL, session: session)
            }
        }
    }

    // MARK: - Headers, delays, repeats

    @Test("A step's own Content-Type replaces the default instead of duplicating it")
    func customContentTypeWins() async throws {
        let journey = Journey(
            name: "XML",
            steps: [
                JourneyStep(
                    name: "xml",
                    method: .get,
                    path: "/feed",
                    outcome: .respond(JourneyResponse(
                        statusCode: 200,
                        headers: ["Content-Type": "application/xml", "X-Trace": "abc"],
                        body: "<feed/>"
                    ))
                )
            ]
        )

        try await Self.withEngine(journey: journey) { _, baseURL in
            let reply = try await Self.call("GET", "feed", baseURL: baseURL, session: Self.session())
            #expect(reply.status == 200)
            #expect(reply.headers["Content-Type"] == "application/xml")
            #expect(reply.headers["X-Trace"] == "abc")
        }
    }

    @Test("Step delay and global delay both apply to the wire")
    func delaysApplyOnTheWire() async throws {
        let journey = Journey(
            name: "Slow",
            steps: [
                JourneyStep(
                    name: "slow",
                    method: .get,
                    path: "/inbox",
                    outcome: .respond(JourneyResponse(statusCode: 200, body: "slow")),
                    delayMs: 300
                )
            ]
        )

        try await Self.withEngine(journey: journey, globalDelayMs: 150) { _, baseURL in
            let started = Date()
            let reply = try await Self.call("GET", "inbox", baseURL: baseURL, session: Self.session())
            let elapsed = Date().timeIntervalSince(started)

            #expect(reply.status == 200)
            #expect(elapsed >= 0.45, "expected the 150ms global + 300ms step delay, got \(elapsed)s")
        }
    }

    @Test("A repeating step answers the configured number of times before advancing")
    func repeatingStepPollsOverHTTP() async throws {
        let journey = try Self.journeyFromTemplate("progressive-loading")

        try await Self.withEngine(journey: journey) { _, baseURL in
            let session = Self.session()
            let accepted = try await Self.call("POST", "reports", baseURL: baseURL, session: session)
            #expect(accepted.status == 202)

            var polls: [Int] = []
            for _ in 0..<4 {
                polls.append(try await Self.call("GET", "reports/job_44", baseURL: baseURL, session: session).status)
            }
            #expect(polls == [202, 202, 202, 200])
        }
    }

    @Test("Concurrent requests never consume the same step twice")
    func concurrentRequestsConsumeDistinctSteps() async throws {
        // Ten identical routes, each scripted with a distinct status. If the cursor were advanced
        // with a read-then-write race, two requests would observe the same status.
        let statuses = [500, 501, 502, 503, 504, 505, 506, 507, 508, 509]
        let journey = Journey(
            name: "Race",
            steps: statuses.map { status in
                JourneyStep(
                    name: "step-\(status)",
                    method: .get,
                    path: "/inbox",
                    outcome: .respond(JourneyResponse(statusCode: status))
                )
            }
        )

        try await Self.withEngine(journey: journey) { _, baseURL in
            let session = Self.session()
            let observed = try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in statuses.indices {
                    group.addTask {
                        try await Self.call("GET", "inbox", baseURL: baseURL, session: session).status
                    }
                }
                var result: [Int] = []
                for try await status in group { result.append(status) }
                return result
            }

            #expect(Set(observed) == Set(statuses), "each step must be served exactly once")
        }
    }

    // MARK: - Runtime control

    @Test("Restarting the journey mid-run rewinds it so the flow replays")
    func restartRewindsALiveJourney() async throws {
        let journey = try Self.journeyFromTemplate("retry-after-failure")

        try await Self.withEngine(journey: journey) { engine, baseURL in
            let session = Self.session()
            _ = try await Self.call("POST", "login", baseURL: baseURL, session: session)
            let failed = try await Self.call("GET", "account-summary", baseURL: baseURL, session: session)
            #expect(failed.status == 500)

            let status = try #require(await engine.restartJourney())
            #expect(status.currentStepIndex == 0)
            #expect(status.totalServed == 0)

            // After a restart the flow starts over: the summary fails again.
            _ = try await Self.call("POST", "login", baseURL: baseURL, session: session)
            let refailed = try await Self.call("GET", "account-summary", baseURL: baseURL, session: session)
            #expect(refailed.status == 500)
        }
    }

    @Test("Advancing skips the held step, which is how maintenance mode is lifted")
    func advanceLiftsAHeldStep() async throws {
        let journey = try Self.journeyFromTemplate("maintenance-window")

        try await Self.withEngine(journey: journey) { engine, baseURL in
            let session = Self.session()
            let first = try await Self.call("GET", "account-summary", baseURL: baseURL, session: session)
            let second = try await Self.call("GET", "account-summary", baseURL: baseURL, session: session)
            let held: [Int] = [first.status, second.status]
            #expect(held == [503, 503])

            _ = await engine.advanceJourney()

            let lifted = try await Self.call("GET", "account-summary", baseURL: baseURL, session: session)
            #expect(lifted.status == 200)
        }
    }

    @Test("Status tracks progress while requests are being served")
    func statusTracksLiveProgress() async throws {
        let journey = try Self.journeyFromTemplate("retry-after-failure")

        try await Self.withEngine(journey: journey) { engine, baseURL in
            let session = Self.session()
            var status = try #require(await engine.journeyStatus())
            #expect(status.currentStepIndex == 0)

            _ = try await Self.call("POST", "login", baseURL: baseURL, session: session)
            status = try #require(await engine.journeyStatus())
            #expect(status.currentStepIndex == 1)
            #expect(status.totalServed == 1)
            #expect(status.steps[0].isExhausted)
        }
    }

    @Test("Journey control reports nothing when no journey is active")
    func controlIsInertWithoutAJourney() async throws {
        try await Self.withEngine { engine, _ in
            let status = await engine.journeyStatus()
            let restarted = await engine.restartJourney()
            let advanced = await engine.advanceJourney()
            #expect(status == nil)
            #expect(restarted == nil)
            #expect(advanced == nil)
        }
    }

    @Test("Switching the active journey starts the new one from step one")
    func switchingJourneysResetsProgress() async throws {
        let first = try Self.journeyFromTemplate("retry-after-failure", name: "First")
        let second = try Self.journeyFromTemplate("payment-retry", name: "Second")

        try await Self.withEngine(journey: first) { engine, baseURL in
            let session = Self.session()
            _ = try await Self.call("POST", "login", baseURL: baseURL, session: session)

            await engine.updateConfiguration(endpoints: [], globalDelayMs: 0, journey: second)

            let status = try #require(await engine.journeyStatus())
            #expect(status.journeyName == "Second")
            #expect(status.currentStepIndex == 0)

            let declined = try await Self.call("POST", "payments", baseURL: baseURL, session: session)
            #expect(declined.status == 402)
        }
    }

    @Test("Editing a live journey's steps resets the run rather than pointing into the old sequence")
    func editingStepsResetsTheRun() async throws {
        var journey = try Self.journeyFromTemplate("payment-retry")

        try await Self.withEngine(journey: journey) { engine, baseURL in
            let session = Self.session()
            let declined = try await Self.call("POST", "payments", baseURL: baseURL, session: session)
            #expect(declined.status == 402)

            // Same journey id, different steps.
            journey.steps.insert(
                JourneyStep(
                    name: "prelude",
                    method: .post,
                    path: "/payments",
                    outcome: .respond(JourneyResponse(statusCode: 409))
                ),
                at: 0
            )
            await engine.updateConfiguration(endpoints: [], globalDelayMs: 0, journey: journey)

            let status = try #require(await engine.journeyStatus())
            #expect(status.currentStepIndex == 0)
            let afterEdit = try await Self.call("POST", "payments", baseURL: baseURL, session: session)
            #expect(afterEdit.status == 409)
        }
    }

    @Test("Clearing the journey returns the server to plain endpoint mocking")
    func clearingTheJourney() async throws {
        let journey = Journey(
            name: "Override",
            steps: [
                JourneyStep(name: "fail", method: .get, path: "/inbox", outcome: .respond(JourneyResponse(statusCode: 500)))
            ]
        )
        let endpoints = [Self.endpoint(.get, "/inbox", 200, body: "endpoint-body")]

        try await Self.withEngine(endpoints: endpoints, journey: journey) { engine, baseURL in
            let session = Self.session()
            let overridden = try await Self.call("GET", "inbox", baseURL: baseURL, session: session)
            #expect(overridden.status == 500)

            await engine.updateConfiguration(endpoints: endpoints, globalDelayMs: 0, journey: nil)

            let reply = try await Self.call("GET", "inbox", baseURL: baseURL, session: session)
            let clearedStatus = await engine.journeyStatus()
            #expect(reply.status == 200)
            #expect(reply.body == "endpoint-body")
            #expect(clearedStatus == nil)
        }
    }

    // MARK: - Request log

    @Test("Served requests are logged with journey attribution")
    func logsRecordJourneyAttribution() async throws {
        let journey = try Self.journeyFromTemplate("retry-after-failure")

        try await Self.withEngine(journey: journey) { engine, baseURL in
            let collector = LogCollector()
            let stream = engine.logStream
            let drain = Task { for await entry in stream { await collector.append(entry) } }
            defer { drain.cancel() }

            let session = Self.session()
            _ = try await Self.call("POST", "login", baseURL: baseURL, session: session)
            _ = try await Self.call("GET", "account-summary", baseURL: baseURL, session: session)

            try await collector.waitForCount(2)
            let logs = await collector.entries

            #expect(logs.count >= 2)
            #expect(logs[0].path == "/login")
            #expect(logs[0].responseStatusCode == 200)
            #expect(logs[0].matchedJourneyID == journey.id)
            #expect(logs[0].matchedJourneyStepID == journey.steps[0].id)
            #expect(logs[1].responseStatusCode == 500)
            #expect(logs[1].failureLabel == nil)
        }
    }

    @Test("The log records the response the client actually received")
    func logsRecordTheResponse() async throws {
        let journey = Journey(
            name: "Rate limited",
            steps: [
                JourneyStep(
                    name: "429",
                    method: .get,
                    path: "/inbox",
                    outcome: .respond(JourneyResponse(
                        statusCode: 429,
                        headers: ["Retry-After": "30"],
                        body: #"{"error":"rate_limited"}"#
                    ))
                )
            ]
        )

        try await Self.withEngine(journey: journey) { engine, baseURL in
            let collector = LogCollector()
            let stream = engine.logStream
            let drain = Task { for await entry in stream { await collector.append(entry) } }
            defer { drain.cancel() }

            let reply = try await Self.call("GET", "inbox", baseURL: baseURL, session: Self.session())
            try await collector.waitForCount(1)
            let logged = try #require(await collector.entries.first)

            // The point of the feature: the log alone answers "what did the client get?".
            #expect(logged.responseStatusCode == reply.status)
            #expect(logged.responseBody == reply.body)
            #expect(logged.responseHeaders["Retry-After"] == "30")
            #expect(logged.responseHeaders["Content-Type"] == "application/json")
            #expect(logged.responseBodyTruncated == false)
            #expect(logged.outcome == .journey)
        }
    }

    @Test("A request with no configuration is logged as unmatched, not merely as a 404")
    func logsMarkUnmatchedRequests() async throws {
        try await Self.withEngine(endpoints: [Self.endpoint(.get, "/inbox", 200)]) { engine, baseURL in
            let collector = LogCollector()
            let stream = engine.logStream
            let drain = Task { for await entry in stream { await collector.append(entry) } }
            defer { drain.cancel() }

            _ = try await Self.call("GET", "inbox", baseURL: baseURL, session: Self.session())
            _ = try await Self.call("GET", "never-configured", baseURL: baseURL, session: Self.session())

            try await collector.waitForCount(2)
            let logs = await collector.entries
            #expect(logs[0].outcome == .endpoint)
            #expect(logs[1].outcome == .unmatched)
            #expect(logs[1].outcome.isMissingConfiguration)
        }
    }

    @Test("A failed request is logged as a failure, not as a fabricated status code")
    func logsRecordFailuresHonestly() async throws {
        let journey = Journey(
            name: "Offline",
            steps: [
                JourneyStep(name: "drop", method: .get, path: "/inbox", outcome: .networkFailure(.connectionDrop))
            ]
        )

        try await Self.withEngine(journey: journey) { engine, baseURL in
            let collector = LogCollector()
            let stream = engine.logStream
            let drain = Task { for await entry in stream { await collector.append(entry) } }
            defer { drain.cancel() }

            _ = try? await Self.call("GET", "inbox", baseURL: baseURL, session: Self.session(timeout: 5))

            try await collector.waitForCount(1)
            let logs = await collector.entries
            #expect(logs[0].failureLabel == "connection-drop")
            #expect(logs[0].responseStatusCode == nil)
            // Nothing was written, so recording a body would be a fiction.
            #expect(logs[0].responseBody == nil)
            #expect(logs[0].responseHeaders.isEmpty)
        }
    }
}

/// Collects log entries off the engine's stream. An actor because the stream is drained on one task
/// while assertions read from another.
actor LogCollector {
    private(set) var entries: [RequestLog] = []

    func append(_ entry: RequestLog) {
        entries.append(entry)
    }

    /// Polls until `count` entries have arrived, or fails after a bounded wait. Polling — rather than
    /// a fixed sleep — keeps the suite fast when the stream is prompt and honest when it is not.
    func waitForCount(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while entries.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(entries.count >= count, "expected \(count) log entries, saw \(entries.count)")
    }
}
