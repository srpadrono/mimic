import Foundation
import Testing
@testable import Domain

/// Journeys are only useful if they are *deterministic*, so these tests drive a journey the way a
/// client would — a sequence of requests in, a sequence of responses out — and assert the whole
/// trace rather than one call at a time.
@Suite("Journey resolution")
struct JourneyResolutionTests {

    // MARK: - Helpers

    /// Replays requests through a journey, threading the run state exactly as the engine does.
    /// Returns what a client would observe for each request.
    static func replay(
        _ requests: [(HTTPMethod, String)],
        journey: Journey,
        endpoints: [Endpoint] = [],
        globalDelayMs: Int = 0
    ) -> [Observed] {
        var state = JourneyRunState(journeyID: journey.id)
        return requests.map { method, path in
            let plan = MockResolver.plan(
                request: IncomingRequest(method: method, path: path),
                endpoints: endpoints,
                globalDelayMs: globalDelayMs,
                journey: journey,
                journeyState: state
            )
            if let next = plan.journeyState { state = next }
            return Observed(plan.response)
        }
    }

    struct Observed: Equatable, CustomStringConvertible {
        let statusCode: Int
        let body: String?
        let delayMs: Int
        let failure: NetworkFailure?
        let fromJourney: Bool

        init(_ response: ResolvedResponse) {
            statusCode = response.statusCode
            body = response.body
            delayMs = response.delayMs
            failure = response.failure
            fromJourney = response.matchedJourneyID != nil
        }

        var description: String {
            failure.map { "failure(\($0))" } ?? "\(statusCode)"
        }
    }

    static func step(
        _ method: HTTPMethod,
        _ path: String,
        _ statusCode: Int,
        body: String? = nil,
        delayMs: Int = 0,
        repeatCount: Int = 1
    ) -> JourneyStep {
        JourneyStep(
            name: "\(method.rawValue) \(path) -> \(statusCode)",
            method: method,
            path: path,
            outcome: .respond(JourneyResponse(statusCode: statusCode, body: body)),
            delayMs: delayMs,
            repeatCount: repeatCount
        )
    }

    static func endpoint(_ method: HTTPMethod, _ path: String, _ statusCode: Int) -> Endpoint {
        let scenario = Scenario(name: "Default", statusCode: statusCode, body: "endpoint")
        return Endpoint(
            name: "\(method.rawValue) \(path)",
            method: method,
            path: path,
            scenarios: [scenario],
            activeScenarioID: scenario.id
        )
    }

    /// The journey from the product goal.
    static var canonical: Journey {
        Journey(
            name: "Retry after failure",
            steps: [
                step(.post, "/login", 200),
                step(.get, "/account-summary", 500),
                step(.get, "/inbox", 200),
                step(.get, "/account-summary", 200),
            ]
        )
    }

    // MARK: - The canonical flow

    @Test("The same endpoint returns different responses depending on where it falls in the journey")
    func canonicalFlow() {
        let observed = Self.replay(
            [
                (.post, "/login"),
                (.get, "/account-summary"),
                (.get, "/inbox"),
                (.get, "/account-summary"),
            ],
            journey: Self.canonical
        )

        #expect(observed.map(\.statusCode) == [200, 500, 200, 200])
        #expect(observed.map(\.fromJourney) == [true, true, true, true])
    }

    @Test("A client that reorders calls still gets each route's responses in journey order")
    func outOfOrderCallsStillAdvancePerRoute() {
        // Real clients fire concurrently: the summary request lands before login completes.
        let observed = Self.replay(
            [
                (.get, "/account-summary"),
                (.post, "/login"),
                (.get, "/account-summary"),
            ],
            journey: Self.canonical
        )

        // The first summary still fails and the second still succeeds — the pending /login step is
        // skipped over rather than blocking, then consumed when it does arrive.
        #expect(observed.map(\.statusCode) == [500, 200, 200])
    }

    @Test("strictSequence refuses anything but the step at the cursor")
    func strictSequenceBlocksOutOfOrderCalls() {
        var journey = Self.canonical
        journey.matchMode = .strictSequence
        journey.unmatchedBehavior = .notFound

        let observed = Self.replay(
            [
                (.get, "/account-summary"), // out of order — step 0 is POST /login
                (.post, "/login"),
                (.get, "/account-summary"),
            ],
            journey: journey
        )

        #expect(observed.map(\.statusCode) == [404, 200, 500])
        #expect(observed[0].fromJourney == false)
        #expect(observed[0].body == ResolvedResponse.journeyBlocked.body)
    }

    // MARK: - Unmatched behavior

    @Test("Unscripted requests fall through to the endpoint's active scenario by default")
    func fallsThroughToEndpoints() {
        let journey = Journey(name: "Partial", steps: [Self.step(.get, "/account-summary", 500)])
        let observed = Self.replay(
            [(.get, "/settings"), (.get, "/account-summary")],
            journey: journey,
            endpoints: [Self.endpoint(.get, "/settings", 200)]
        )

        #expect(observed[0].statusCode == 200)
        #expect(observed[0].body == "endpoint")
        #expect(observed[0].fromJourney == false)
        #expect(observed[1].statusCode == 500)
        #expect(observed[1].fromJourney)
    }

    @Test("notFound makes an unscripted call fail loudly instead of silently succeeding")
    func blocksUnscriptedCallsWhenAsked() {
        var journey = Journey(name: "Strict", steps: [Self.step(.get, "/account-summary", 500)])
        journey.unmatchedBehavior = .notFound

        let observed = Self.replay(
            [(.get, "/settings")],
            journey: journey,
            endpoints: [Self.endpoint(.get, "/settings", 200)]
        )

        #expect(observed[0].statusCode == 404)
        #expect(observed[0].body == "Request is not part of the active journey.")
    }

    @Test("A request outside the script never consumes a step")
    func unmatchedRequestsLeaveTheCursorAlone() {
        let journey = Journey(name: "Partial", steps: [Self.step(.get, "/account-summary", 500)])
        let observed = Self.replay(
            [(.get, "/settings"), (.get, "/settings"), (.get, "/account-summary")],
            journey: journey
        )

        #expect(observed[2].statusCode == 500, "the scripted step must survive unrelated traffic")
    }

    // MARK: - Progression

    @Test("repeatCount serves the same step several times before moving on")
    func repeatCountHoldsAStep() {
        let journey = Journey(
            name: "Polling",
            steps: [
                Self.step(.get, "/reports/:id", 202, repeatCount: 3),
                Self.step(.get, "/reports/:id", 200),
            ]
        )

        let observed = Self.replay(
            Array(repeating: (HTTPMethod.get, "/reports/job_44"), count: 5),
            journey: journey
        )

        // Three polls pending, then complete; the exhausted journey falls through afterwards.
        #expect(observed.map(\.statusCode) == [202, 202, 202, 200, 404])
    }

    @Test("Wildcard steps match any value in that segment")
    func wildcardStepsMatch() {
        let journey = Journey(name: "Wildcard", steps: [Self.step(.get, "/users/:id", 404)])
        let observed = Self.replay([(.get, "/users/9182")], journey: journey)
        #expect(observed[0].statusCode == 404)
    }

    @Test("Query strings do not affect step matching")
    func queryStringsAreIgnored() {
        let journey = Journey(name: "Query", steps: [Self.step(.get, "/inbox", 204)])
        let observed = Self.replay([(.get, "/inbox?page=2&unread=true")], journey: journey)
        #expect(observed[0].statusCode == 204)
    }

    @Test("A completed journey stops answering and lets endpoints take over")
    func completionStops() {
        let journey = Journey(name: "Short", steps: [Self.step(.get, "/inbox", 500)])
        let observed = Self.replay(
            [(.get, "/inbox"), (.get, "/inbox")],
            journey: journey,
            endpoints: [Self.endpoint(.get, "/inbox", 200)]
        )

        #expect(observed.map(\.statusCode) == [500, 200])
        #expect(observed[1].fromJourney == false)
    }

    @Test("completion .restart replays the journey forever")
    func completionRestarts() {
        var journey = Journey(
            name: "Loop",
            steps: [Self.step(.get, "/inbox", 500), Self.step(.get, "/inbox", 200)]
        )
        journey.completion = .restart

        let observed = Self.replay(
            Array(repeating: (HTTPMethod.get, "/inbox"), count: 5),
            journey: journey
        )

        #expect(observed.map(\.statusCode) == [500, 200, 500, 200, 500])
    }

    @Test("autoAdvance off holds the current step until something advances it")
    func autoAdvanceOffHoldsTheStep() {
        var journey = Journey(
            name: "Maintenance",
            steps: [Self.step(.get, "/account-summary", 503), Self.step(.get, "/account-summary", 200)]
        )
        journey.autoAdvance = false

        var state = JourneyRunState(journeyID: journey.id)
        var observed: [Int] = []
        for callIndex in 0..<4 {
            // Advance manually after the third call — the "bring the backend back up" switch.
            if callIndex == 3 { state = state.advancing(in: journey) }
            let plan = MockResolver.plan(
                request: IncomingRequest(method: .get, path: "/account-summary"),
                endpoints: [],
                globalDelayMs: 0,
                journey: journey,
                journeyState: state
            )
            if let next = plan.journeyState { state = next }
            observed.append(plan.response.statusCode)
        }

        #expect(observed == [503, 503, 503, 200])
    }

    @Test("A manual advance retires the current step without serving it")
    func manualAdvanceSkipsAStep() {
        let journey = Self.canonical
        var state = JourneyRunState(journeyID: journey.id)
        state = state.advancing(in: journey) // skip POST /login

        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/account-summary"),
            endpoints: [],
            globalDelayMs: 0,
            journey: journey,
            journeyState: state
        )

        #expect(plan.response.statusCode == 500)
        #expect(state.cursor == 1)
    }

    @Test("Restarting rewinds the run so the journey replays from step one")
    func restartRewinds() {
        let journey = Self.canonical
        var state = JourneyRunState(journeyID: journey.id)
        state = state.recordingServe(of: journey.steps[0], in: journey)
        state = state.recordingServe(of: journey.steps[1], in: journey)
        #expect(state.cursor == 2)

        state = state.restarted()
        #expect(state.cursor == 0)
        #expect(state.totalServed == 0)
        #expect(state.isComplete == false)
    }

    // MARK: - Delays and failures

    @Test("Step delay and global delay stack, matching endpoint delay arithmetic")
    func delaysAreAdditive() {
        let journey = Journey(name: "Slow", steps: [Self.step(.get, "/inbox", 200, delayMs: 250)])
        let observed = Self.replay([(.get, "/inbox")], journey: journey, globalDelayMs: 100)
        #expect(observed[0].delayMs == 350)
    }

    @Test("Network-failure steps resolve to a failure plan, not a status code")
    func networkFailuresResolveAsFailures() {
        let journey = Journey(
            name: "Offline",
            steps: [
                JourneyStep(name: "drop", method: .get, path: "/inbox", outcome: .networkFailure(.connectionDrop)),
                JourneyStep(
                    name: "timeout",
                    method: .get,
                    path: "/inbox",
                    outcome: .networkFailure(.timeout(holdMs: 1_500))
                ),
                Self.step(.get, "/inbox", 200),
            ]
        )

        let observed = Self.replay(
            Array(repeating: (HTTPMethod.get, "/inbox"), count: 3),
            journey: journey
        )

        #expect(observed[0].failure == .connectionDrop)
        #expect(observed[1].failure == .timeout(holdMs: 1_500))
        #expect(observed[2].failure == nil)
        #expect(observed[2].statusCode == 200)
    }

    @Test("Custom headers and bodies survive resolution")
    func headersAndBodiesAreServed() {
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

        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/inbox"),
            endpoints: [],
            globalDelayMs: 0,
            journey: journey,
            journeyState: JourneyRunState(journeyID: journey.id)
        )

        #expect(plan.response.headers["Retry-After"] == "30")
        #expect(plan.response.body == #"{"error":"rate_limited"}"#)
        #expect(plan.response.contentType == .json)
    }

    // MARK: - Isolation

    @Test("Run state from a different journey never leaks progress into this one")
    func stateFromAnotherJourneyIsDiscarded() {
        let other = Journey(name: "Other", steps: [Self.step(.get, "/x", 200)])
        var foreignState = JourneyRunState(journeyID: other.id)
        foreignState = foreignState.recordingServe(of: other.steps[0], in: other)

        let journey = Self.canonical
        let plan = MockResolver.plan(
            request: IncomingRequest(method: .post, path: "/login"),
            endpoints: [],
            globalDelayMs: 0,
            journey: journey,
            journeyState: foreignState
        )

        #expect(plan.response.statusCode == 200, "must start at step 0 of the new journey")
        #expect(plan.journeyState?.journeyID == journey.id)
    }

    @Test("With no journey active, resolution is plain endpoint matching")
    func noJourneyMeansPlainEndpointResolution() {
        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/inbox"),
            endpoints: [Self.endpoint(.get, "/inbox", 201)],
            globalDelayMs: 0
        )

        #expect(plan.response.statusCode == 201)
        #expect(plan.journeyState == nil)
    }

    @Test("An empty journey is inert rather than a wall")
    func emptyJourneyFallsThrough() {
        let journey = Journey(name: "Empty")
        let observed = Self.replay(
            [(.get, "/inbox")],
            journey: journey,
            endpoints: [Self.endpoint(.get, "/inbox", 200)]
        )
        #expect(observed[0].statusCode == 200)
    }

    // MARK: - Reporting

    @Test("Status reports the cursor, per-step progress, and completion")
    func statusReportsProgress() {
        let journey = Self.canonical
        var state = JourneyRunState(journeyID: journey.id)

        var status = JourneyStatus.make(journey: journey, state: state)
        #expect(status.totalSteps == 4)
        #expect(status.currentStepIndex == 0)
        #expect(status.isComplete == false)
        #expect(status.steps[0].isCurrent)
        #expect(status.steps[0].statusCode == 200)

        state = state.recordingServe(of: journey.steps[0], in: journey)
        status = JourneyStatus.make(journey: journey, state: state)
        #expect(status.currentStepIndex == 1)
        #expect(status.steps[0].isExhausted)
        #expect(status.steps[0].servedCount == 1)
        #expect(status.totalServed == 1)

        for step in journey.steps.dropFirst() {
            state = state.recordingServe(of: step, in: journey)
        }
        status = JourneyStatus.make(journey: journey, state: state)
        #expect(status.isComplete)
        #expect(status.currentStepIndex == nil)
    }

    @Test("Status of a never-run journey reports a fresh run, not an error")
    func statusToleratesMissingState() {
        let status = JourneyStatus.make(journey: Self.canonical, state: nil)
        #expect(status.totalServed == 0)
        #expect(status.currentStepIndex == 0)
    }

    @Test("Failure steps are labelled in reports since they have no status code")
    func statusLabelsFailures() {
        let journey = Journey(
            name: "Offline",
            steps: [
                JourneyStep(name: "drop", method: .get, path: "/a", outcome: .networkFailure(.connectionDrop)),
                JourneyStep(name: "hang", method: .get, path: "/b", outcome: .networkFailure(.timeout(holdMs: 5_000))),
            ]
        )
        let status = JourneyStatus.make(journey: journey, state: nil)
        #expect(status.steps[0].failure == "connection-drop")
        #expect(status.steps[0].statusCode == nil)
        #expect(status.steps[1].failure == "timeout(5000ms)")
    }

    @Test("Run state round-trips through JSON so a host can persist a partial run")
    func runStateIsCodable() throws {
        let journey = Self.canonical
        var state = JourneyRunState(journeyID: journey.id)
        state = state.recordingServe(of: journey.steps[0], in: journey)
        state = state.advancing(in: journey)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(JourneyRunState.self, from: data)
        #expect(decoded == state)
    }
}
