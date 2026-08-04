import Foundation
import Testing
@testable import Domain

/// Turning an observed request into a scripted step is how a journey usually grows: you are already
/// looking at the exact exchange you want to replay. These pin that the captured step reproduces it.
@Suite("Capturing a logged request as a journey step")
struct JourneyStepCaptureTests {

    static func log(
        method: HTTPMethod = .get,
        path: String = "/account-summary",
        status: Int? = 200,
        headers: [String: String] = ["Content-Type": "application/json"],
        body: String? = #"{"balance":10}"#,
        outcome: RequestOutcome = .endpoint
    ) -> RequestLog {
        RequestLog(
            method: method,
            path: path,
            responseStatusCode: status,
            responseHeaders: headers,
            responseBody: body,
            outcome: outcome
        )
    }

    @Test("The captured step reproduces the response the client received")
    func capturesTheResponse() {
        let spec = JourneyStepSpec.capturing(
            Self.log(
                method: .post,
                path: "/payments",
                status: 402,
                headers: ["Content-Type": "application/json", "Retry-After": "5"],
                body: #"{"error":"card_declined"}"#
            )
        )

        #expect(spec.method == .post)
        #expect(spec.path == "/payments")
        #expect(spec.statusCode == 402)
        #expect(spec.body == #"{"error":"card_declined"}"#)
        #expect(spec.contentType == .json)
        #expect(spec.headers?["Retry-After"] == "5")
    }

    @Test("Content-Type is modelled once, not repeated as a header")
    func contentTypeIsNotDuplicated() {
        let spec = JourneyStepSpec.capturing(Self.log())
        // The step already carries the content type; emitting it as a header too would write it twice.
        #expect(spec.contentType == .json)
        #expect(spec.headers?["Content-Type"] == nil)
    }

    @Test("A step with no headers beyond the content type carries none")
    func noSpuriousEmptyHeaders() {
        let spec = JourneyStepSpec.capturing(Self.log(headers: ["Content-Type": "text/plain"]))
        #expect(spec.headers == nil)
        #expect(spec.contentType == .plainText)
    }

    @Test("The query string is dropped, because it belongs to the call and not the route")
    func queryStringIsDropped() {
        let spec = JourneyStepSpec.capturing(Self.log(path: "/inbox?page=2&unread=true"))
        #expect(spec.path == "/inbox")
    }

    @Test("A step defaults to a name naming its route")
    func defaultName() {
        #expect(JourneyStepSpec.capturing(Self.log(method: .put, path: "/things/9")).name == "PUT /things/9")
        #expect(JourneyStepSpec.capturing(Self.log(), name: "Chosen").name == "Chosen")
    }

    @Test("An unmatched request keeps its status but not Mimic's own diagnostic body")
    func unmatchedKeepsStatusOnly() {
        let spec = JourneyStepSpec.capturing(
            Self.log(
                path: "/never-mocked",
                status: 404,
                headers: ["Content-Type": "text/plain"],
                body: "No mock endpoint matched.",
                outcome: .unmatched
            )
        )

        // Scripting a 404 at this point in a flow is reasonable; baking in Mimic's diagnostic text is
        // not — it is not a response any real backend would send.
        #expect(spec.statusCode == 404)
        #expect(spec.body == nil)
        #expect(spec.headers == nil)
    }

    @Test("A request an active journey blocked is treated the same way")
    func blockedKeepsStatusOnly() {
        let spec = JourneyStepSpec.capturing(
            Self.log(body: "Request is not part of the active journey.", outcome: .blockedByJourney)
        )
        #expect(spec.body == nil)
    }

    @Test("A captured step round-trips into a real journey and serves what was observed")
    func capturedStepServesTheSameResponse() throws {
        var project = MockProject(name: "Captured")
        _ = try ProjectCommandExecutor.apply(.journeyCreate(name: "Flow", spec: nil), to: &project)

        let observed = Self.log(
            path: "/account-summary",
            status: 500,
            headers: ["Content-Type": "application/json", "X-Trace": "abc"],
            body: #"{"error":"boom"}"#
        )
        _ = try ProjectCommandExecutor.apply(
            .journeyStepAdd(journey: .name("Flow"), step: .capturing(observed), atIndex: nil),
            to: &project
        )

        let journey = try #require(project.journeys.first)
        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/account-summary"),
            endpoints: [],
            globalDelayMs: 0,
            journey: journey,
            journeyState: JourneyRunState(journeyID: journey.id)
        )

        // What the client saw is what the journey now replays.
        #expect(plan.response.statusCode == 500)
        #expect(plan.response.body == #"{"error":"boom"}"#)
        #expect(plan.response.headers["X-Trace"] == "abc")
        #expect(plan.response.contentType == .json)
    }

    @Test("A path without a leading slash is normalized so the step is valid")
    func pathIsNormalized() {
        #expect(JourneyStepSpec.capturing(Self.log(path: "inbox")).path == "/inbox")
    }
}

/// Capturing a whole run of traffic is how a journey gets built from a session rather than one click
/// at a time. Ordering, exclusion and collapsing are the rules that matter, and each of them fails
/// silently — a journey with its steps in the wrong order looks perfectly reasonable on screen.
@Suite("Capturing a run of logged requests as a journey")
struct JourneySessionCaptureTests {

    static func log(
        _ path: String,
        at secondsSinceEpoch: TimeInterval,
        method: HTTPMethod = .get,
        status: Int? = 200,
        body: String? = #"{"balance":10}"#,
        outcome: RequestOutcome = .endpoint
    ) -> RequestLog {
        RequestLog(
            timestamp: Date(timeIntervalSince1970: secondsSinceEpoch),
            method: method,
            path: path,
            responseStatusCode: status,
            responseHeaders: ["Content-Type": "application/json"],
            responseBody: body,
            outcome: outcome
        )
    }

    @Test("Steps follow the order the calls arrived, not the order they were handed over")
    func ordersChronologically() {
        // Newest-first is the log's default sort, so this reversed order is what a selection normally
        // arrives in. Capturing it as given would replay the whole flow backwards.
        let steps = JourneyStepSpec.capturing([
            Self.log("/third", at: 300),
            Self.log("/first", at: 100),
            Self.log("/second", at: 200),
        ])

        #expect(steps.map(\.path) == ["/first", "/second", "/third"])
    }

    @Test("Requests logged in the same instant keep the order they were given")
    func tiesAreDeterministic() {
        // `sorted(by:)` promises no stability, so without the index tiebreak these could swap between
        // runs — and a journey that captures differently each time is not reproducible.
        let steps = JourneyStepSpec.capturing([
            Self.log("/a", at: 100),
            Self.log("/b", at: 100),
            Self.log("/c", at: 100),
        ])

        #expect(steps.map(\.path) == ["/a", "/b", "/c"])
    }

    @Test("Requests a journey already answered are left out")
    func dropsRequestsAlreadyInAJourney() {
        let steps = JourneyStepSpec.capturing([
            Self.log("/login", at: 100),
            Self.log("/scripted", at: 200, outcome: .journey),
            Self.log("/inbox", at: 300),
        ])

        #expect(steps.map(\.path) == ["/login", "/inbox"])
    }

    @Test("A run of identical polls becomes one step that repeats")
    func collapsesConsecutiveRepeats() {
        let steps = JourneyStepSpec.capturing([
            Self.log("/status", at: 100, status: 202, body: #"{"state":"pending"}"#),
            Self.log("/status", at: 200, status: 202, body: #"{"state":"pending"}"#),
            Self.log("/status", at: 300, status: 202, body: #"{"state":"pending"}"#),
        ])

        #expect(steps.count == 1)
        #expect(steps.first?.repeatCount == 3)
    }

    @Test("A poll that changes its answer keeps the transition")
    func doesNotCollapseAcrossAChangedResponse() {
        let steps = JourneyStepSpec.capturing([
            Self.log("/status", at: 100, status: 202, body: #"{"state":"pending"}"#),
            Self.log("/status", at: 200, status: 202, body: #"{"state":"pending"}"#),
            Self.log("/status", at: 300, status: 200, body: #"{"state":"done"}"#),
        ])

        // Collapsing all three would erase the exact thing the journey is being captured to
        // reproduce: that the third call answered differently from the first two.
        #expect(steps.count == 2)
        #expect(steps.first?.repeatCount == 2)
        #expect(steps.last?.statusCode == 200)
        #expect(steps.last?.repeatCount == nil)
    }

    @Test("Identical calls separated by another call stay separate steps")
    func onlyConsecutiveRunsCollapse() {
        let steps = JourneyStepSpec.capturing([
            Self.log("/summary", at: 100),
            Self.log("/inbox", at: 200),
            Self.log("/summary", at: 300),
        ])

        #expect(steps.map(\.path) == ["/summary", "/inbox", "/summary"])
        #expect(steps.allSatisfy { $0.repeatCount == nil })
    }

    @Test("Two calls to one route that answered differently are not collapsed")
    func differingStatusesStayApart() {
        // The failure-then-retry flow is the reason journeys exist at all.
        let steps = JourneyStepSpec.capturing([
            Self.log("/account-summary", at: 100, status: 500, body: #"{"error":"boom"}"#),
            Self.log("/account-summary", at: 200, status: 200, body: #"{"balance":10}"#),
        ])

        #expect(steps.map(\.statusCode) == [500, 200])
    }

    @Test("A selection with nothing capturable yields no steps")
    func emptySelection() {
        #expect(JourneyStepSpec.capturing([]).isEmpty)
        #expect(JourneyStepSpec.capturing([Self.log("/x", at: 100, outcome: .journey)]).isEmpty)
    }

    @Test("A captured run replays through a real journey in the order it was observed")
    func capturedRunReplaysInOrder() throws {
        var project = MockProject(name: "Captured")
        _ = try ProjectCommandExecutor.apply(
            .journeyCreate(
                name: "Retry flow",
                // Handed over newest-first, the way the log draws it.
                spec: JourneySpec(steps: JourneyStepSpec.capturing([
                    Self.log("/account-summary", at: 200, status: 200, body: #"{"balance":10}"#),
                    Self.log("/account-summary", at: 100, status: 500, body: #"{"error":"boom"}"#),
                ]))
            ),
            to: &project
        )

        let journey = try #require(project.journeys.first)
        var state = JourneyRunState(journeyID: journey.id)
        let observed = (0..<2).map { _ -> Int in
            let plan = MockResolver.plan(
                request: IncomingRequest(method: .get, path: "/account-summary"),
                endpoints: [],
                globalDelayMs: 0,
                journey: journey,
                journeyState: state
            )
            if let next = plan.journeyState { state = next }
            return plan.response.statusCode
        }

        // The failure came first in time, so it must come first in the journey.
        #expect(observed == [500, 200])
    }
}
