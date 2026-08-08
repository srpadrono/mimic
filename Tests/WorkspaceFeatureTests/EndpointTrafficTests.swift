import Foundation
import Testing
import Domain
@testable import AppFeatures

/// Answering "has anything actually called this endpoint?" from the request log the app already
/// keeps — every `RequestLog` records the endpoint that answered it.
///
/// This suite used to be four times longer, covering a sort order, a summary string and a status
/// breakdown. All three belonged to the traffic panel retired in #26, and all three kept passing
/// afterwards with no production caller left — which is the failure mode worth naming: a green test
/// is not evidence that the code under it is reachable. They went when the count replaced them.
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

    // MARK: - Counting

    @Test("Only the requests this endpoint answered are counted")
    func countsOnlyMatchingEndpoint() {
        let endpointID = UUID()
        let other = UUID()

        let logs = [
            Self.log(endpointID: endpointID),
            Self.log(endpointID: other),
            Self.log(endpointID: endpointID),
            Self.log(endpointID: nil)
        ]

        #expect(EndpointTrafficQuery.count(forEndpoint: endpointID, in: logs) == 2)
        #expect(EndpointTrafficQuery.count(forEndpoint: other, in: logs) == 1)
    }

    @Test("An endpoint nothing has called counts zero")
    func countsZeroWhenNothingMatched() {
        let unused = UUID()

        #expect(EndpointTrafficQuery.count(forEndpoint: unused, in: []) == 0)
        #expect(EndpointTrafficQuery.count(forEndpoint: unused, in: [Self.log(endpointID: UUID())]) == 0)
    }

    /// An unmatched call and a journey-answered call both carry a nil `matchedEndpointID`. Neither
    /// belongs to any endpoint's history, and counting them against one would put a number beside an
    /// endpoint that never ran.
    @Test("Requests no endpoint answered belong to no endpoint")
    func unattributedRequestsCountAgainstNobody() {
        let endpointID = UUID()

        let logs = [
            Self.log(endpointID: endpointID),
            Self.log(endpointID: nil, status: 404, outcome: .unmatched),
            Self.log(endpointID: nil, outcome: .journey)
        ]

        #expect(EndpointTrafficQuery.count(forEndpoint: endpointID, in: logs) == 1)
    }
}
