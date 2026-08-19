import Foundation
import Testing
@testable import Domain

/// The log filter, which used to be two predicates in two modules that agreed by coincidence.
@Suite("Request log filter")
struct RequestLogFilterTests {

    private func log(
        method: HTTPMethod = .get,
        path: String = "/api/orders",
        status: Int? = 200,
        endpointID: UUID? = nil,
        journeyID: UUID? = nil,
        outcome: RequestOutcome = .endpoint
    ) -> RequestLog {
        RequestLog(
            method: method,
            path: path,
            requestHeaders: [:],
            requestBody: nil,
            matchedEndpointID: endpointID,
            matchedScenarioID: nil,
            responseStatusCode: status,
            responseHeaders: [:],
            responseBody: nil,
            matchedJourneyID: journeyID,
            matchedJourneyStepID: nil,
            outcome: outcome
        )
    }

    @Test("An empty filter is inert and returns the collection untouched")
    func emptyFilterKeepsEverything() {
        let entries = [log(), log(path: "/api/users"), log(status: 404, outcome: .unmatched)]
        #expect(RequestLogFilter.none.apply(to: entries).count == 3)
        #expect(RequestLogFilter.none.isActive == false)
    }

    @Test("unmatchedOnly keeps calls nothing answered")
    func unmatchedOnly() {
        let entries = [log(), log(status: 404, outcome: .unmatched), log()]
        let filtered = RequestLogFilter(unmatchedOnly: true).apply(to: entries)
        #expect(filtered.count == 1)
        #expect(filtered.first?.outcome == .unmatched)
    }

    @Test("journeyOnly is not the complement of unmatchedOnly")
    func journeyOnlyIsNotTheComplementOfUnmatched() {
        // The distinction that makes two toggles rather than one tri-state: a call blocked by an
        // active journey is neither unmatched nor served by one, so it belongs to *neither* filter.
        let journeyID = UUID()
        let entries = [
            log(journeyID: journeyID, outcome: .journey),
            log(status: 404, outcome: .unmatched),
            log(outcome: .blockedByJourney),
            log(),
        ]

        let journeys = RequestLogFilter(journeyOnly: true).apply(to: entries)
        let unmatched = RequestLogFilter(unmatchedOnly: true).apply(to: entries)

        #expect(journeys.count == 1)
        #expect(unmatched.count == 1)
        // Four entries, and the two filters between them account for only two of them.
        #expect(journeys.count + unmatched.count < entries.count)
    }

    @Test("Method and endpoint narrow independently, and compose")
    func methodAndEndpointCompose() {
        let target = UUID()
        let entries = [
            log(method: .get, endpointID: target),
            log(method: .post, endpointID: target),
            log(method: .get, endpointID: UUID()),
        ]

        #expect(RequestLogFilter(method: .get).apply(to: entries).count == 2)
        #expect(RequestLogFilter(endpointID: target).apply(to: entries).count == 2)
        #expect(RequestLogFilter(method: .get, endpointID: target).apply(to: entries).count == 1)
    }

    @Test("Text matches the path, the status code and the outcome label — case-insensitively")
    func textMatchesTheThreeScannedFields() {
        let entries = [
            log(path: "/api/Orders"),
            log(path: "/api/users", status: 404, outcome: .unmatched),
            log(path: "/health", status: 500),
        ]

        #expect(RequestLogFilter(text: "orders").apply(to: entries).count == 1, "path, case-insensitive")
        #expect(RequestLogFilter(text: "404").apply(to: entries).count == 1, "status code")
        #expect(RequestLogFilter(text: "unmatched").apply(to: entries).count == 1, "outcome label")
    }

    @Test("Text does NOT search bodies — the field has never promised it and a payload scan is a stall")
    func textDoesNotSearchBodies() {
        let entry = RequestLog(
            method: .post,
            path: "/api/orders",
            requestHeaders: [:],
            requestBody: "{\"needle\":true}",
            matchedEndpointID: nil,
            matchedScenarioID: nil,
            responseStatusCode: 200,
            responseHeaders: [:],
            responseBody: "{\"needle\":true}",
            matchedJourneyID: nil,
            matchedJourneyStepID: nil,
            outcome: .endpoint
        )
        #expect(RequestLogFilter(text: "needle").apply(to: [entry]).isEmpty)
    }

    @Test("isActive tells 'no requests yet' apart from 'no requests match'")
    func isActiveDistinguishesTheTwoEmptyStates() {
        // Four separate conditions used to choose between those two sentences.
        #expect(RequestLogFilter.none.isActive == false)
        #expect(RequestLogFilter(unmatchedOnly: true).isActive)
        #expect(RequestLogFilter(journeyOnly: true).isActive)
        #expect(RequestLogFilter(method: .get).isActive)
        #expect(RequestLogFilter(endpointID: UUID()).isActive)
        #expect(RequestLogFilter(text: "x").isActive)
    }

    @Test("Order is preserved — a filter narrows, it does not re-sort")
    func orderIsPreserved() {
        let entries = [log(path: "/c"), log(path: "/a"), log(path: "/b")]
        let filtered = RequestLogFilter(method: .get).apply(to: entries)
        #expect(filtered.map(\.path) == ["/c", "/a", "/b"])
    }
}
