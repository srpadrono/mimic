import Foundation
import Testing
@testable import Domain

/// The request log's most valuable line is *"nothing here is configured for this call"*. These pin
/// that it stays distinguishable — the reason `RequestOutcome` exists at all is that inferring it
/// from a nil endpoint id broke the moment journeys could also answer without one.
@Suite("Request outcome")
struct RequestOutcomeTests {

    static func endpoint(_ method: HTTPMethod, _ path: String, _ status: Int = 200) -> Endpoint {
        let scenario = Scenario(name: "Default", statusCode: status)
        return Endpoint(
            name: "\(method.rawValue) \(path)",
            method: method,
            path: path,
            scenarios: [scenario],
            activeScenarioID: scenario.id
        )
    }

    @Test("A request an endpoint answers is reported as an endpoint match")
    func endpointMatch() {
        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/inbox"),
            endpoints: [Self.endpoint(.get, "/inbox")],
            globalDelayMs: 0
        )
        #expect(plan.response.outcome == .endpoint)
        #expect(plan.response.outcome.isMissingConfiguration == false)
    }

    @Test("A request nothing matches is reported as unmatched, not merely as a 404")
    func unmatchedIsNamed() {
        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/not-configured"),
            endpoints: [Self.endpoint(.get, "/inbox")],
            globalDelayMs: 0
        )
        #expect(plan.response.outcome == .unmatched)
        #expect(plan.response.outcome.isMissingConfiguration)
        #expect(plan.response.statusCode == 404)
    }

    @Test("An endpoint that deliberately returns 404 is not reported as missing configuration")
    func deliberate404IsNotUnmatched() {
        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/gone"),
            endpoints: [Self.endpoint(.get, "/gone", 404)],
            globalDelayMs: 0
        )
        // This is exactly why the status code alone cannot be the signal.
        #expect(plan.response.statusCode == 404)
        #expect(plan.response.outcome == .endpoint)
        #expect(plan.response.outcome.isMissingConfiguration == false)
    }

    @Test("A journey step answering is not mistaken for a missing mock")
    func journeyAnswerIsNotUnmatched() {
        let journey = Journey(
            name: "Flow",
            steps: [
                JourneyStep(
                    name: "summary",
                    method: .get,
                    path: "/account-summary",
                    outcome: .respond(JourneyResponse(statusCode: 500))
                )
            ]
        )
        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/account-summary"),
            endpoints: [],
            globalDelayMs: 0,
            journey: journey,
            journeyState: JourneyRunState(journeyID: journey.id)
        )

        // Before `RequestOutcome` this case and `unmatched` were indistinguishable: both had a nil
        // endpoint id and rendered as an em dash.
        #expect(plan.response.outcome == .journey)
        #expect(plan.response.outcome.isMissingConfiguration == false)
        #expect(plan.response.matchedEndpointID == nil)
    }

    @Test("A journey step that fails the connection is still a journey answer")
    func journeyFailureIsAJourneyAnswer() {
        let journey = Journey(
            name: "Offline",
            steps: [
                JourneyStep(name: "drop", method: .get, path: "/inbox", outcome: .networkFailure(.connectionDrop))
            ]
        )
        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/inbox"),
            endpoints: [],
            globalDelayMs: 0,
            journey: journey,
            journeyState: JourneyRunState(journeyID: journey.id)
        )
        #expect(plan.response.outcome == .journey)
        #expect(plan.response.failure == .connectionDrop)
    }

    @Test("A journey refusing an unscripted call is 'blocked', not 'missing configuration'")
    func blockedIsDistinctFromUnmatched() {
        var journey = Journey(
            name: "Strict",
            steps: [
                JourneyStep(
                    name: "summary",
                    method: .get,
                    path: "/account-summary",
                    outcome: .respond(JourneyResponse(statusCode: 200))
                )
            ]
        )
        journey.unmatchedBehavior = .notFound

        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/settings"),
            endpoints: [Self.endpoint(.get, "/settings")],
            globalDelayMs: 0,
            journey: journey,
            journeyState: JourneyRunState(journeyID: journey.id)
        )

        // The configuration here is deliberate, so flagging it as a missing mock would be wrong.
        #expect(plan.response.outcome == .blockedByJourney)
        #expect(plan.response.outcome.isMissingConfiguration == false)
    }

    @Test("An unscripted call that falls through to nothing is still a missing mock")
    func fallThroughToNothingIsUnmatched() {
        let journey = Journey(
            name: "Partial",
            steps: [
                JourneyStep(
                    name: "summary",
                    method: .get,
                    path: "/account-summary",
                    outcome: .respond(JourneyResponse(statusCode: 200))
                )
            ]
        )
        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/never-mocked"),
            endpoints: [],
            globalDelayMs: 0,
            journey: journey,
            journeyState: JourneyRunState(journeyID: journey.id)
        )
        #expect(plan.response.outcome == .unmatched)
        #expect(plan.response.outcome.isMissingConfiguration)
    }

    @Test("Outcomes have labels and round-trip through JSON for the CLI")
    func outcomesAreReportable() throws {
        #expect(RequestOutcome.unmatched.label == "Unmatched")
        #expect(RequestOutcome.journey.label == "Journey")
        #expect(RequestOutcome.endpoint.label == "Endpoint")
        #expect(RequestOutcome.blockedByJourney.label == "Blocked")

        for outcome in RequestOutcome.allCases {
            let data = try JSONEncoder().encode(outcome)
            #expect(try JSONDecoder().decode(RequestOutcome.self, from: data) == outcome)
        }
    }

    @Test("A response body is capped so a thousand logged requests cannot exhaust memory")
    func responseBodyIsCapped() {
        let small = String(repeating: "a", count: 100)
        let (kept, truncated) = RequestLog.cappedBody(small)
        #expect(kept == small)
        #expect(truncated == false)

        let huge = String(repeating: "b", count: RequestLog.maxLoggedBodyBytes + 5_000)
        let (cappedBody, wasTruncated) = RequestLog.cappedBody(huge)
        #expect(wasTruncated)
        #expect((cappedBody?.utf8.count ?? 0) <= RequestLog.maxLoggedBodyBytes)

        let (none, noneTruncated) = RequestLog.cappedBody(nil)
        #expect(none == nil)
        #expect(noneTruncated == false)
    }

    @Test("A logged request carries the outcome so the UI and CLI read the same value")
    func logCarriesOutcome() throws {
        let log = RequestLog(method: .get, path: "/nope", responseStatusCode: 404, outcome: .unmatched)
        let json = try ControlCoding.string(log)
        #expect(json.contains(#""outcome":"unmatched""#))

        let decoded = try ControlCoding.decode(RequestLog.self, from: Data(json.utf8))
        #expect(decoded.outcome == .unmatched)
    }
}
