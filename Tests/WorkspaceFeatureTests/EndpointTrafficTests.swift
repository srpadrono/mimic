import Foundation
import Testing
import Domain
@testable import AppFeatures
@testable import EndpointsFeature

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
}
