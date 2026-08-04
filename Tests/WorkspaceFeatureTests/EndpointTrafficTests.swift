import Foundation
import Testing
import Domain
@testable import AppFeatures

/// Answering "has anything actually called this endpoint?" from the request log the app already
/// keeps — every `RequestLog` records the endpoint that answered it.
@Suite("Endpoint traffic")
struct EndpointTrafficTests {

    // MARK: - Fixtures

    /// A fixed instant, so ordering assertions never depend on when the suite happens to run.
    static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    static func log(
        endpointID: UUID? = nil,
        secondsAfterAnchor: TimeInterval = 0,
        method: HTTPMethod = .get,
        path: String = "/api/users",
        status: Int? = 200,
        failureLabel: String? = nil,
        outcome: RequestOutcome = .endpoint
    ) -> RequestLog {
        RequestLog(
            timestamp: anchor.addingTimeInterval(secondsAfterAnchor),
            method: method,
            path: path,
            matchedEndpointID: endpointID,
            responseStatusCode: status,
            failureLabel: failureLabel,
            outcome: outcome
        )
    }

    // MARK: - Filtering

    @Test("Only the requests this endpoint answered come back")
    func filtersByMatchedEndpoint() {
        let endpointID = UUID()
        let mine = Self.log(endpointID: endpointID, path: "/mine")
        let anotherEndpoint = Self.log(endpointID: UUID(), path: "/theirs")
        let unmatched = Self.log(path: "/not-mocked", status: 404, outcome: .unmatched)
        // A journey step answers without a matched endpoint, exactly as an unmatched call does —
        // both must stay out of this endpoint's history.
        let journey = Self.log(path: "/scripted", outcome: .journey)

        let result = EndpointTrafficQuery.logs(
            forEndpoint: endpointID,
            in: [anotherEndpoint, mine, unmatched, journey]
        )

        #expect(result.map(\.id) == [mine.id])
    }

    @Test("An endpoint nothing has called has no traffic")
    func filtersToNothingWhenUnused() {
        let unused = UUID()

        #expect(EndpointTrafficQuery.logs(forEndpoint: unused, in: []).isEmpty)
        #expect(EndpointTrafficQuery.logs(forEndpoint: unused, in: [Self.log(endpointID: UUID())]).isEmpty)
    }

    // MARK: - Ordering

    @Test("Requests come back newest first")
    func ordersNewestFirst() {
        let endpointID = UUID()
        let oldest = Self.log(endpointID: endpointID, secondsAfterAnchor: 0)
        let middle = Self.log(endpointID: endpointID, secondsAfterAnchor: 30)
        let newest = Self.log(endpointID: endpointID, secondsAfterAnchor: 60)

        // Arrival order — the order the request log itself keeps, since it appends.
        let result = EndpointTrafficQuery.logs(forEndpoint: endpointID, in: [oldest, middle, newest])

        #expect(result.map(\.id) == [newest.id, middle.id, oldest.id])
    }

    @Test("Requests sharing a timestamp keep a stable, arrival-reversed order")
    func breaksTimestampTiesDeterministically() {
        // `sorted(by:)` promises nothing about equal elements, so without an explicit tie-break the
        // list could reorder itself between redraws — which reads as a bug, not as sorting.
        let endpointID = UUID()
        let first = Self.log(endpointID: endpointID, path: "/first")
        let second = Self.log(endpointID: endpointID, path: "/second")

        let result = EndpointTrafficQuery.logs(forEndpoint: endpointID, in: [first, second])

        #expect(result.map(\.path) == ["/second", "/first"])
    }

    // MARK: - Summary

    @Test("The summary counts requests and pluralises")
    func summaryPluralises() {
        let one = [Self.log()]
        let twelve = (0..<12).map { Self.log(secondsAfterAnchor: TimeInterval($0)) }

        #expect(EndpointTrafficQuery.summary(for: one) == "1 request")
        #expect(EndpointTrafficQuery.summary(for: twelve) == "12 requests")
    }

    @Test("No traffic reads as a sentence rather than \"0 requests\"")
    func summaryForEmptyInput() {
        #expect(EndpointTrafficQuery.summary(for: []) == "No requests")
    }

    @Test("The failure clause appears only when something actually failed")
    func summaryReportsFailures() {
        let answered = Self.log(status: 200)
        let unmatched = Self.log(status: 404, outcome: .unmatched)
        let dropped = Self.log(status: nil, failureLabel: "connection-drop")

        #expect(EndpointTrafficQuery.summary(for: [answered, answered]) == "2 requests")
        #expect(EndpointTrafficQuery.summary(for: [answered, unmatched]) == "2 requests \u{00B7} 1 failed")
        #expect(EndpointTrafficQuery.summary(for: [answered, dropped]) == "2 requests \u{00B7} 1 failed")
        #expect(EndpointTrafficQuery.summary(for: [unmatched, dropped]) == "2 requests \u{00B7} 2 failed")
    }

    @Test("A configured 500 is an answer, not a failure")
    func serverErrorIsNotAFailure() {
        // The mock was told to return 500 and did. Counting it as a failure would put a warning on
        // the one panel meant to say the endpoint is behaving as configured.
        #expect(EndpointTrafficQuery.summary(for: [Self.log(status: 500)]) == "1 request")
    }

    // MARK: - Status breakdown

    @Test("Status codes are counted, most frequent first")
    func breaksDownStatusCodes() {
        let logs = [
            Self.log(status: 404),
            Self.log(status: 200),
            Self.log(status: 500),
            Self.log(status: 200),
            Self.log(status: 404),
            Self.log(status: 200),
        ]

        let breakdown = EndpointTrafficQuery.statusBreakdown(for: logs)

        #expect(breakdown.map { $0.code } == [200, 404, 500])
        #expect(breakdown.map { $0.count } == [3, 2, 1])
    }

    @Test("Equally common codes are ordered by code, so the row cannot reshuffle")
    func breaksCountTiesByCode() {
        // A dictionary has no order of its own; without the tie-break these three would come out in
        // whatever order hashing produced on the day.
        let logs = [Self.log(status: 503), Self.log(status: 201), Self.log(status: 404)]

        #expect(EndpointTrafficQuery.statusBreakdown(for: logs).map { $0.code } == [201, 404, 503])
    }

    @Test("A failed connection contributes no status code")
    func excludesFailuresFromBreakdown() {
        // A dropped connection has no status. Folding it in as a 0 would put a pill on screen for a
        // status no server ever sent; the summary's failure clause reports it instead.
        let logs = [Self.log(status: 200), Self.log(status: nil, failureLabel: "timeout(30000ms)")]

        let breakdown = EndpointTrafficQuery.statusBreakdown(for: logs)

        #expect(breakdown.map { $0.code } == [200])
        #expect(breakdown.map { $0.count } == [1])
    }

    @Test("No requests means no breakdown")
    func breakdownForEmptyInput() {
        #expect(EndpointTrafficQuery.statusBreakdown(for: []).isEmpty)
    }
}
