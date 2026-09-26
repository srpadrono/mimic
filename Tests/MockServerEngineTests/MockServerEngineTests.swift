import Testing
import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in FoundationNetworking on Linux, not Foundation. Without this the CLI and the
// tests that speak HTTP do not compile there — and CI runs on Linux.
import FoundationNetworking
#endif
import Domain
@testable import MockServerEngine

/// Many cases here bind a real socket, so the suite carries a time limit: a bind that never
/// completes, or a wait on a stream that never yields, otherwise hangs the whole run with no
/// indication of which test is stuck. One minute is the finest granularity `.timeLimit` offers and is
/// far above what any of these needs — the point is a bound, not a deadline.
///
/// The rest deliberately bind nothing. Error mapping, the lifecycle refusals, and the route store's
/// own decisions are all reachable without a listener, and a case that needs no port should not take
/// one — it is one more thing that can fail for a reason the test is not about. This header used to
/// open "every case here binds a real socket", which was untrue of several of them before this
/// sentence was written and is why the claim is now a shape rather than a count.
@Suite("MockServerEngine", .serialized, .timeLimit(.minutes(1)))
struct MockServerEngineTests {

    /// Every sibling suite in this target already asks the OS for a port; this file was the one
    /// holding 18080–18084 by hand. A fixed port fails on the machine that happens to have something
    /// on it, and fails again on the run that starts while the previous socket is still in
    /// `TIME_WAIT` — both of which read as a broken engine rather than a broken test.
    static func freePort() throws -> Int {
        try #require(PlatformSocket.freePort())
    }

    /// The first entry `stream` yields, or `nil` if none arrives inside `limit`.
    ///
    /// The bound is what replaces `try await Task.sleep(for: .seconds(1))`: that cost every run a
    /// second whether or not the entry had already landed, and said nothing at all if the stream had
    /// simply stopped — the test failed on `receivedLog != nil` with no hint of why. This returns the
    /// moment the entry arrives and gives up rather than hanging when it does not.
    static func firstLogEntry(
        from stream: AsyncStream<RequestLog>,
        within limit: Duration
    ) async -> RequestLog? {
        await withTaskGroup(of: RequestLog?.self) { group in
            group.addTask {
                for await entry in stream { return entry }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test func startAndStopSucceeds() async throws {
        let engine = MockServerEngine()
        let config = ServerConfiguration(port: try Self.freePort(), globalDelayMs: 0)
        try await engine.start(configuration: config)
        try await engine.stop()
    }

    @Test func doubleStartThrowsAlreadyRunning() async throws {
        try await JourneyServingTests.withEngine { engine, baseURL in
            let config = ServerConfiguration(port: try #require(baseURL.port), globalDelayMs: 0)
            do {
                try await engine.start(configuration: config)
                Issue.record("A second start must be refused")
            } catch let error as MockServerError {
                guard case .alreadyRunning = error else {
                    Issue.record("Expected alreadyRunning, got \(error)")
                    return
                }
            }
        }
    }

    @Test func stopWhenNotRunningThrowsNotRunning() async {
        let engine = MockServerEngine()
        do {
            try await engine.stop()
            Issue.record("Stopping an idle engine must be refused")
        } catch let error as MockServerError {
            guard case .notRunning = error else {
                Issue.record("Expected notRunning, got \(error)")
                return
            }
        } catch {
            Issue.record(error)
        }
    }

    @Test("Invalid primary and named listener ports are refused before binding", arguments: [
        Int.min, -1, 0, 65_536, Int.max,
    ])
    func invalidListenerPortsAreRefused(port: Int) async throws {
        let validPort = try Self.freePort()
        for isNamed in [false, true] {
            let engine = MockServerEngine()
            let configuration = ServerConfiguration(
                port: isNamed ? validPort : port,
                globalDelayMs: 0,
                backends: isNamed ? [BackendConfiguration(name: "Accounts", port: port)] : []
            )
            var refused = false
            do {
                try await engine.start(configuration: configuration)
            } catch let error as MockServerError {
                if case .invalidConfiguration = error { refused = true }
                else { Issue.record("Expected invalidConfiguration for port \(port), got \(error)") }
            } catch {
                Issue.record(error)
            }
            #expect(refused, "Invalid port \(port) must be refused for \(isNamed ? "named" : "primary") listener")
            #expect(await engine.isRunning == false)
            if await engine.isRunning { try await engine.stop() }
        }
    }

    @Test("A refused named listener leaves the primary port available for a corrected start")
    func validStartAfterInvalidListener() async throws {
        let port = try Self.freePort()
        let engine = MockServerEngine()
        let invalid = ServerConfiguration(
            port: port, globalDelayMs: 0,
            backends: [BackendConfiguration(name: "Accounts", port: 0)]
        )
        await #expect(throws: MockServerError.self) {
            try await engine.start(configuration: invalid)
        }
        guard await engine.isRunning == false else {
            try await engine.stop()
            return
        }

        try await engine.start(configuration: ServerConfiguration(port: port, globalDelayMs: 0))
        do {
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/missing"))
            let (_, response) = try await URLSession.shared.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 404)
        } catch {
            try? await engine.stop()
            throw error
        }
        try await engine.stop()
    }

    /// This called `updateConfiguration` twice and asserted nothing at all — its whole claim was that
    /// a non-`throws`, non-returning function did not trap, which it cannot. The configuration goes
    /// into a `MockRouteStore` the engine holds privately, so the observation has to come back out
    /// through the engine: `journeyStatus()` is a straight read of that store and needs no socket.
    ///
    /// It also pins the difference between the endpoints-only overload and the ones that carry a
    /// journey, which is the part a caller can get wrong: a form taking `journey:` replaces the
    /// journey, the two-argument form leaves it alone. `MockServerRuntime.updateMocks` calls one of
    /// the journey-carrying forms on every project change, so a two-argument call that quietly
    /// cleared the journey would stop a running flow mid-run.
    @Test func updateConfigurationReachesTheRouteStore() async {
        let engine = MockServerEngine()
        let scenario = Scenario(name: "Success", statusCode: 200, body: "{}")
        let endpoint = Endpoint(name: "Test", method: .get, path: "/test",
                                scenarios: [scenario], activeScenarioID: scenario.id)
        let journey = Journey(
            name: "Flow",
            steps: [
                JourneyStep(
                    name: "one",
                    method: .get,
                    path: "/test",
                    outcome: .respond(JourneyResponse(statusCode: 503))
                ),
            ]
        )

        #expect(await engine.journeyStatus() == nil, "a fresh engine has no journey")

        await engine.updateConfiguration(endpoints: [endpoint], globalDelayMs: 0, journey: journey)
        let loaded = await engine.journeyStatus()
        #expect(loaded?.journeyName == "Flow")
        #expect(loaded?.totalSteps == 1)
        #expect(loaded?.currentStepIndex == 0)

        // An endpoints-only update must not disturb the run: the store keeps `journey` and `runState`
        // out of the two-argument path entirely.
        await engine.updateConfiguration(endpoints: [])
        #expect(await engine.journeyStatus()?.journeyName == "Flow")

        // …and clearing it explicitly does.
        await engine.updateConfiguration(endpoints: [], globalDelayMs: 0, journey: nil)
        #expect(await engine.journeyStatus() == nil)
    }

    /// Whether a push is an activation is compared against a **high-water mark**, not for equality
    /// and not for difference, and both halves of that matter.
    ///
    /// The engine's API makes no ordering promise: `MockServerRuntime.updateMocks` chains its pushes
    /// so the production sequence arrives in dispatch order, but nothing holds a direct caller to
    /// that discipline, so the store guards its own door against a push landing after a newer one.
    /// A straggler carrying an epoch that a newer push already superseded must not rewind
    /// the run that newer push started, and it must not lower the mark either, or the epoch still in
    /// force would look like a fresh activation the next time an ordinary edit re-sends the project.
    ///
    /// No socket: `advanceJourney()` moves the cursor exactly as a served request would, and what is
    /// under test is the store's decision, not the wire.
    @Test("An out-of-order configuration push does not restart the run")
    func supersededActivationEpochDoesNotRestartTheRun() async throws {
        let engine = MockServerEngine()
        let journey = Journey(
            name: "Flow",
            steps: [
                JourneyStep(
                    name: "one",
                    method: .get,
                    path: "/a",
                    outcome: .respond(JourneyResponse(statusCode: 500))
                ),
                JourneyStep(
                    name: "two",
                    method: .get,
                    path: "/a",
                    outcome: .respond(JourneyResponse(statusCode: 200))
                ),
            ]
        )

        await engine.updateConfiguration(endpoints: [], globalDelayMs: 0, journey: journey, activationEpoch: 2)
        _ = await engine.advanceJourney()
        let midRun = try #require(await engine.journeyStatus())
        #expect(midRun.currentStepIndex == 1)

        // Epoch 1 was overtaken by epoch 2 above: a straggler, not an activation.
        await engine.updateConfiguration(endpoints: [], globalDelayMs: 0, journey: journey, activationEpoch: 1)
        let afterStraggler = try #require(await engine.journeyStatus())
        #expect(afterStraggler.currentStepIndex == 1)

        // The epoch still in force, re-sent — which is every project mutation between one activation
        // and the next. It only stays inert because the straggler did not lower the mark.
        await engine.updateConfiguration(endpoints: [], globalDelayMs: 0, journey: journey, activationEpoch: 2)
        let afterRePush = try #require(await engine.journeyStatus())
        #expect(afterRePush.currentStepIndex == 1)

        // …and the next real activation still lands.
        await engine.updateConfiguration(endpoints: [], globalDelayMs: 0, journey: journey, activationEpoch: 3)
        let afterActivation = try #require(await engine.journeyStatus())
        #expect(afterActivation.currentStepIndex == 0)
    }

    @Test func logStreamYieldsEntryAfterHTTPRequest() async throws {
        try await JourneyServingTests.withEngine { engine, baseURL in
            let stream = engine.logStream
            let url = baseURL.appendingPathComponent("anything")

            try await confirmation("the served request is yielded to the log stream") { logged in
                // Attach before sending so this also covers delivery while a consumer is waiting.
                async let entry = Self.firstLogEntry(from: stream, within: .seconds(5))
                let (_, response) = try await URLSession.shared.data(from: url)
                #expect((response as? HTTPURLResponse)?.statusCode == 404)

                let received = await entry
                #expect(received?.path == "/anything")
                if received != nil { logged() }
            }
        }
    }

    // MARK: - Lifecycle reentrancy

    /// `stop()` clears `app` and *then* awaits the shutdown, and an actor admits another call at that
    /// suspension. A `start` arriving in that window used to see `app == nil`, pass the guard, and try
    /// to bind a port the outgoing application had not released — so the caller was told the port was
    /// in use by something else, when the something else was Mimic's own previous listener.
    ///
    /// The window is a real race, so the assertion is on the *outcome set* rather than on one
    /// ordering: whichever way the two land, a start racing a stop must never come back as
    /// `portInUse`. Before the guard that was the answer whenever the start landed inside the window;
    /// after it the three possible answers are `alreadyRunning` (the start reached the actor first),
    /// `invalidState(.stopping)` (it landed inside the window and was told to retry), and success (the
    /// stop had already finished).
    ///
    /// The `Task.yield()` and the repeat count bias the timing toward the interesting ordering
    /// without depending on it — nothing here can *make* the stop reach its suspension first, and a
    /// test that only passes when it does would be a flake in the other direction. What is asserted
    /// holds in every ordering, so this fails only for the reason it names.
    @Test("A start racing a stop is never told the port is in use")
    func startDuringStopIsRefusedRatherThanColliding() async throws {
        let port = try Self.freePort()
        let config = ServerConfiguration(port: port, globalDelayMs: 0)

        for attempt in 1...5 {
            let engine = MockServerEngine()
            try await engine.start(configuration: config)

            let stopping = Task { try await engine.stop() }
            await Task.yield()

            var raced: (any Error)?
            do {
                try await engine.start(configuration: config)
            } catch {
                raced = error
            }
            _ = try? await stopping.value

            if let engineError = raced as? MockServerError, case let .portInUse(reported) = engineError {
                Issue.record("attempt \(attempt): a start racing a stop reported port \(reported) in use")
            }
            // Whatever happened, the engine agrees with itself afterwards, and the port is released
            // before the next attempt.
            if raced == nil {
                #expect(await engine.isRunning, "the racing start succeeded but the engine says it is not running")
            }
            try? await engine.stop()
            #expect(await engine.isRunning == false)
        }
    }

    @Test("Stopping releases a delayed request while preserving its queued log across restart")
    func stopCancelsRunDelaysWithoutDiscardingLogs() async throws {
        let engine = MockServerEngine()
        let port = try Self.freePort()
        let configuration = ServerConfiguration(port: port, globalDelayMs: 0)
        let scenario = Scenario(name: "Slow", statusCode: 200, body: "before restart")
        var endpoint = Endpoint(
            name: "Slow", path: "/slow", scenarios: [scenario],
            activeScenarioID: scenario.id, delayMs: 30_000
        )
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/slow"))
        await engine.updateConfiguration(endpoints: [endpoint])
        try await engine.start(configuration: configuration)
        let session = JourneyServingTests.session()
        defer { session.invalidateAndCancel() }
        let pending = Task { try await session.data(from: url) }

        do {
            // The log is published before the artificial wait. Leave it unacknowledged while
            // stopping, so the test distinguishes active-handler cleanup from discarding logs.
            let first = try #require(await Self.firstLogEntry(from: engine.logStream, within: .seconds(5)))
            #expect(first.responseBody == "before restart")
            #expect(await engine.logGate.activeCount == 1)
            #expect(await engine.logGate.outstandingCount == 1)
            pending.cancel()
            _ = try? await pending.value

            try await engine.stop()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await engine.logGate.activeCount != 0, ContinuousClock.now < deadline {
                await Task.yield()
            }
            #expect(await engine.logGate.activeCount == 0, "The stopped run retained its delayed handler")
            #expect(await engine.logGate.outstandingCount == 1, "Stopping must preserve the queued log")

            endpoint.delayMs = 0
            endpoint.scenarios[0].body = "after restart"
            await engine.updateConfiguration(endpoints: [endpoint])
            try await engine.start(configuration: configuration)
            let (data, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self) == "after restart")
            let second = try #require(await Self.firstLogEntry(from: engine.logStream, within: .seconds(5)))
            #expect(second.responseBody == "after restart")
            #expect(await engine.logGate.outstandingCount == 2)
            await engine.acknowledgeLog()
            await engine.acknowledgeLog()
            #expect(await engine.logGate.outstandingCount == 0)
            try await engine.stop()
        } catch {
            pending.cancel()
            _ = try? await pending.value
            try? await engine.stop()
            throw error
        }
    }

    /// The two refusals name different problems, and the difference is what a caller does next:
    /// `alreadyRunning` means "you already have a server", `invalidState(.stopping)` means "ask again
    /// in a moment". They were the same message until the stop window was distinguished from a second
    /// start.
    @Test("The two lifecycle refusals do not say the same thing")
    func lifecycleRefusalsAreDistinguishable() {
        #expect(
            MockServerError.alreadyRunning.errorDescription
                != MockServerError.invalidState(.stopping).errorDescription
        )
        #expect(MockServerError.invalidState(.stopping).errorDescription?.contains("stopping") == true)
    }

    @Test func appliesConfiguredDelayBeforeResponding() async throws {
        let scenario = Scenario(name: "OK", statusCode: 200, body: "{}")
        let endpoint = Endpoint(name: "Slow", method: .get, path: "/slow",
                                scenarios: [scenario], activeScenarioID: scenario.id, delayMs: 150)
        // global (120) + per-endpoint (150) = 270ms minimum
        try await JourneyServingTests.withEngine(endpoints: [endpoint], globalDelayMs: 120) { _, baseURL in
            let url = baseURL.appendingPathComponent("slow")
            let started = ContinuousClock.now
            let (_, response) = try await URLSession.shared.data(from: url)
            let elapsed = ContinuousClock.now - started

            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(elapsed >= .milliseconds(250))
        }
    }

    // MARK: - Error mapping

    @Test func mapStartErrorConvertsAddressInUse() {
        // Simulate an error whose description contains the EADDRINUSE indicator
        struct FakeBindError: Error, CustomStringConvertible {
            var description: String { "address already in use (EADDRINUSE)" }
        }
        let mapped = VaporConfigurator.mapStartError(FakeBindError(), port: 9090)
        guard let engineError = mapped as? MockServerError, case let .portInUse(port) = engineError else {
            Issue.record("Expected portInUse, got \(mapped)")
            return
        }
        #expect(port == 9090)
    }

    @Test func mapStartErrorPassesThroughUnrelatedErrors() {
        struct SomeError: Error {}
        let mapped = VaporConfigurator.mapStartError(SomeError(), port: 9090)
        #expect(mapped is SomeError)
    }

    // MARK: - Route matching integration

    @Test func updateConfigurationAffectsRouteMatching() async throws {
        let scenario = Scenario(name: "OK", statusCode: 200, body: "{\"status\":\"ok\"}")
        let endpoint = Endpoint(name: "Health", method: .get, path: "/health",
                                scenarios: [scenario], activeScenarioID: scenario.id)
        try await JourneyServingTests.withEngine { engine, baseURL in
            let url = baseURL.appendingPathComponent("health")
            let (_, before) = try await URLSession.shared.data(from: url)
            #expect((before as? HTTPURLResponse)?.statusCode == 404)

            await engine.updateConfiguration(endpoints: [endpoint])
            let (data, response) = try await URLSession.shared.data(from: url)
            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(httpResponse.statusCode == 200)
            #expect(String(data: data, encoding: .utf8) == "{\"status\":\"ok\"}")
        }
    }
}
