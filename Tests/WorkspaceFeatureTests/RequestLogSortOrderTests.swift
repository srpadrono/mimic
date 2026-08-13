import Foundation
import Testing
import Domain
@testable import AppFeatures

/// The request log's sort comparator, checked on the case that had no coverage: ties.
///
/// The sort tests in `WorkspaceFeatureLogicTests` — `requestLogQuerySortsByDerivedNames` and
/// `requestLogQueryAdditionalSorts` — each hand `process` exactly two entries that *differ* on the
/// column being sorted, and each assert only what came back `.first`. A comparator can answer every
/// question about a distinct pair correctly and still be broken for equal ones, which is how a
/// descending sort of `!(a < b)` — `a >= b`, true in both directions for a tie — lived here
/// undetected. Every test below therefore uses at least three entries with a genuine duplicate on the
/// sorted column, and pins the whole sequence rather than its head.
///
/// Duplicates are the ordinary case in this panel, not a contrived one: a session repeats methods,
/// paths, status codes, endpoint names and scenario names constantly, and the timestamp is the one
/// column of the six that does not normally hold them.
@Suite("Request log sort order")
@MainActor
struct RequestLogSortOrderTests {
    private struct Fixture {
        let endpoints: [Endpoint]
        let logs: [RequestLog]
    }

    /// Four entries in which every sortable column **but the timestamp** repeats: two
    /// `GET /api/users` answered 200 by the Users endpoint's "OK" scenario, two `POST /api/posts`
    /// answered 201 by Posts' "Created".
    ///
    /// That the timestamps are the one thing distinct across all four is the point: with the
    /// secondary key applied, each column's order becomes a strict *total* order over these rows, so
    /// "one answer, whatever order the rows arrive in" and "descending is the exact reverse of
    /// ascending" are both entailed rather than lucky.
    private func makeFixture() -> Fixture {
        let ok = Scenario(name: "OK", statusCode: 200)
        let empty = Scenario(name: "Empty", statusCode: 200)
        let users = Endpoint(
            name: "Users",
            method: .get,
            path: "/api/users",
            scenarios: [ok, empty],
            activeScenarioID: ok.id
        )
        let created = Scenario(name: "Created", statusCode: 201)
        let posts = Endpoint(
            name: "Posts",
            method: .post,
            path: "/api/posts",
            scenarios: [created],
            activeScenarioID: created.id
        )

        return Fixture(
            endpoints: [users, posts],
            logs: [
                makeLog(endpoint: users, scenario: ok, status: 200, at: 100),
                makeLog(endpoint: users, scenario: ok, status: 200, at: 200),
                makeLog(endpoint: posts, scenario: created, status: 201, at: 300),
                makeLog(endpoint: posts, scenario: created, status: 201, at: 400),
            ]
        )
    }

    private func makeLog(
        endpoint: Endpoint,
        scenario: Scenario,
        status: Int,
        at seconds: TimeInterval
    ) -> RequestLog {
        RequestLog(
            timestamp: Date(timeIntervalSince1970: seconds),
            method: endpoint.method,
            path: endpoint.path,
            matchedEndpointID: endpoint.id,
            matchedScenarioID: scenario.id,
            responseStatusCode: status
        )
    }

    private func sortedIDs(_ fixture: Fixture, field: SortField, ascending: Bool) -> [UUID] {
        RequestLogQuery.process(
            logs: fixture.logs,
            endpoints: fixture.endpoints,
            methodFilter: nil,
            filterText: "",
            sortField: field,
            sortAscending: ascending
        )
        .map(\.id)
    }

    /// Every ordering of `elements`, so a sort can be asked whether it gives the same answer however
    /// the rows reach it — which is the difference between an order that is specified and one that
    /// merely looks settled on the input you happened to try.
    private func permutations<T>(_ elements: [T]) -> [[T]] {
        guard elements.count > 1 else { return [elements] }
        var result: [[T]] = []
        for index in elements.indices {
            var rest = elements
            let picked = rest.remove(at: index)
            for tail in permutations(rest) {
                result.append([picked] + tail)
            }
        }
        return result
    }

    private let allSortFields: [SortField] = [.method, .path, .endpoint, .scenario, .status, .timestamp]

    @Test("Every column sorts to one answer whatever order the rows arrive in")
    func sortIsFullySpecifiedAndReversible() {
        let fixture = makeFixture()
        let orders = permutations(fixture.logs)
        // The sweep is only worth anything if the helper really produced every arrangement; a
        // generator that quietly returned the input would make all the expectations below vacuous.
        #expect(orders.count == 24, "expected 4! arrangements, got \(orders.count)")

        for field in allSortFields {
            let ascending = sortedIDs(fixture, field: field, ascending: true)
            let descending = sortedIDs(fixture, field: field, ascending: false)

            // Descending must be ascending read backwards, and nothing weaker. A comparator that
            // reports two equal rows as ordered gives `sort(by:)` no strict weak ordering and so no
            // guarantee about its output at all — the equal rows do not simply stay put, and what
            // happens to them depends on the arrangement the sort was handed.
            #expect(
                descending == Array(ascending.reversed()),
                "\(field.rawValue) descending is not the reverse of ascending"
            )

            for order in orders {
                let rearranged = Fixture(endpoints: fixture.endpoints, logs: order)
                #expect(
                    sortedIDs(rearranged, field: field, ascending: true) == ascending,
                    "\(field.rawValue) ascending changed with the input order"
                )
                #expect(
                    sortedIDs(rearranged, field: field, ascending: false) == descending,
                    "\(field.rawValue) descending changed with the input order"
                )
            }
        }
    }

    @Test("A duplicated column keeps its run in timestamp order and reverses whole")
    func duplicatedColumnOrdersOnTheTimestampTieBreak() {
        let fixture = makeFixture()
        let ids = fixture.logs.map(\.id)
        let reversed = Array(ids.reversed())

        // Method ties the two GETs against each other and the two POSTs against each other, so this
        // sequence is the tie-break's doing and nothing else's: GET before POST, oldest first inside
        // each run. Descending reverses the tie-break along with the column, so the newest of a set
        // of equals leads.
        #expect(sortedIDs(fixture, field: .method, ascending: true) == ids)
        #expect(sortedIDs(fixture, field: .method, ascending: false) == reversed)

        // Status ties them the same way — 200, 200, 201, 201 — and must land the same way.
        #expect(sortedIDs(fixture, field: .status, ascending: true) == ids)
        #expect(sortedIDs(fixture, field: .status, ascending: false) == reversed)
    }

    @Test("A column with one value sorts entirely on the timestamp, in both directions")
    func wholeColumnTiedFallsBackToTheTimestamp() {
        let endpoint = Endpoint(name: "Users", method: .get, path: "/api/users")
        // Deliberately handed over out of order and with nothing but the timestamp to separate them:
        // an ascending answer of `[middle, oldest, newest]` — the input unchanged — would mean the
        // tie-break never ran, and a descending answer that is not this one reversed would mean the
        // direction was applied to the comparator's *answer* rather than to its operands.
        let newest = makeLog(endpoint: endpoint, scenario: Scenario(name: "OK"), status: 200, at: 300)
        let oldest = makeLog(endpoint: endpoint, scenario: Scenario(name: "OK"), status: 200, at: 100)
        let middle = makeLog(endpoint: endpoint, scenario: Scenario(name: "OK"), status: 200, at: 200)
        let fixture = Fixture(endpoints: [endpoint], logs: [middle, oldest, newest])

        for field in allSortFields {
            #expect(
                sortedIDs(fixture, field: field, ascending: true) == [oldest.id, middle.id, newest.id],
                "\(field.rawValue) ascending did not fall through to the timestamp"
            )
            #expect(
                sortedIDs(fixture, field: field, ascending: false) == [newest.id, middle.id, oldest.id],
                "\(field.rawValue) descending did not fall through to the timestamp"
            )
        }
    }

    @Test("Rows equal on the column and the timestamp compare equal in both directions")
    func fullyEqualRowsAreNotOrdered() {
        let endpoint = Endpoint(name: "Users", method: .get, path: "/api/users")
        let scenario = Scenario(name: "OK")
        // Same column value *and* same timestamp: the tie-break has nothing left to say, so the
        // comparator has to answer `false` each way. Answering `true` in both — which is exactly what
        // negating an ascending `<` does to a tie — is the antisymmetry failure that makes the sort
        // undefined, and it is invisible from any test that only ever compares distinct rows.
        let left = makeLog(endpoint: endpoint, scenario: scenario, status: 200, at: 100)
        let right = makeLog(endpoint: endpoint, scenario: scenario, status: 200, at: 100)

        for field in allSortFields {
            #expect(
                RequestLogQuery.isOrderedBefore(left, right, sortField: field, endpoints: [endpoint]) == false,
                "\(field.rawValue) ordered two equal rows"
            )
            #expect(
                RequestLogQuery.isOrderedBefore(right, left, sortField: field, endpoints: [endpoint]) == false,
                "\(field.rawValue) ordered two equal rows"
            )
        }
    }
}
