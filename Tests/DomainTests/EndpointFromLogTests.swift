import Foundation
import Testing
@testable import Domain

/// Deriving an endpoint from a logged call — the rule the window and the CLI must share.
@Suite("Endpoint from a logged request")
struct EndpointFromLogTests {

    @Test("A query string is stripped, because a query is not part of a route")
    func stripsTheQueryString() {
        // The point of the affordance: an endpoint created from `?page=2` has to answer `?page=3`.
        #expect(EndpointFromLog.mockablePath(from: "/orders?page=2") == "/orders")
        #expect(EndpointFromLog.mockablePath(from: "/orders?page=2&sort=asc") == "/orders")
        #expect(EndpointFromLog.mockablePath(from: "/orders?") == "/orders")
    }

    @Test("A path with no query is unchanged, including its params and trailing slash")
    func leavesOrdinaryPathsAlone() {
        #expect(EndpointFromLog.mockablePath(from: "/api/v1/orders") == "/api/v1/orders")
        #expect(EndpointFromLog.mockablePath(from: "/api/orders/{id}") == "/api/orders/{id}")
        // Not normalised away: `/orders/` and `/orders` are different routes to the matcher, and
        // silently rewriting one into the other would create an endpoint that does not answer the
        // call it was created from.
        #expect(EndpointFromLog.mockablePath(from: "/orders/") == "/orders/")
    }

    @Test("A query-only path degrades to root rather than to a fragment that is not a route")
    func queryOnlyPathBecomesRoot() {
        // `split` would give "a=1" here — not a route at all. This is why the implementation cuts at
        // the separator rather than splitting.
        #expect(EndpointFromLog.mockablePath(from: "?a=1") == "/")
        #expect(EndpointFromLog.mockablePath(from: "") == "/")
        #expect(EndpointFromLog.mockablePath(from: "orders") == "/")
    }

    @Test("The suggested name is the method and the route, and it uses the stripped path")
    func suggestedNameUsesTheStrippedPath() {
        #expect(EndpointFromLog.suggestedName(method: .get, path: "/orders?page=2") == "GET /orders")
        #expect(EndpointFromLog.suggestedName(method: .post, path: "/checkout") == "POST /checkout")
    }

    @Test("The window and the CLI derive byte-identical drafts from one entry")
    func draftIsTheSingleAnswer() {
        // The acceptance criterion this type exists for. Both surfaces call `draft(from:)`, so the
        // only way they can disagree is if this stops being the one implementation.
        let log = RequestLog(
            method: .get,
            path: "/api/orders?page=2",
            requestHeaders: [:],
            requestBody: nil,
            matchedEndpointID: nil,
            matchedScenarioID: nil,
            responseStatusCode: 404,
            responseHeaders: [:],
            responseBody: nil,
            matchedJourneyID: nil,
            matchedJourneyStepID: nil,
            outcome: .unmatched
        )

        let draft = EndpointFromLog.draft(from: log)
        #expect(draft.method == .get)
        #expect(draft.path == "/api/orders")
        #expect(draft.name == "GET /api/orders")

        // Derived twice from the same entry, it is the same draft.
        #expect(EndpointFromLog.draft(from: log) == draft)
    }
}
