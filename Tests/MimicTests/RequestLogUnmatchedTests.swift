import Foundation
import Testing
import Domain
@testable import AppFeatures

/// The drawer's job in this scenario is to answer "what is my app calling that I have not mocked?".
@Suite("Request log — unmatched requests")
struct RequestLogUnmatchedTests {

    static func log(
        _ method: HTTPMethod,
        _ path: String,
        status: Int?,
        outcome: RequestOutcome
    ) -> RequestLog {
        RequestLog(method: method, path: path, responseStatusCode: status, outcome: outcome)
    }

    static let logs: [RequestLog] = [
        log(.post, "/login", status: 200, outcome: .endpoint),
        log(.get, "/account-summary", status: 500, outcome: .journey),
        log(.get, "/not-mocked", status: 404, outcome: .unmatched),
        log(.get, "/gone", status: 404, outcome: .endpoint),
        log(.get, "/also-not-mocked", status: 404, outcome: .unmatched),
    ]

    @Test("The unmatched filter shows only requests with no configuration")
    func filtersToUnmatched() {
        let result = RequestLogQuery.process(
            logs: Self.logs,
            endpoints: [],
            methodFilter: nil,
            filterText: "",
            unmatchedOnly: true,
            sortField: .timestamp,
            sortAscending: true
        )
        #expect(result.map(\.path) == ["/not-mocked", "/also-not-mocked"])
    }

    @Test("An endpoint that deliberately answers 404 is not treated as unmatched")
    func deliberate404IsExcluded() {
        let result = RequestLogQuery.process(
            logs: Self.logs,
            endpoints: [],
            methodFilter: nil,
            filterText: "",
            unmatchedOnly: true,
            sortField: .timestamp,
            sortAscending: true
        )
        #expect(result.contains { $0.path == "/gone" } == false)
    }

    @Test("A journey-served request is not treated as unmatched")
    func journeyServedIsExcluded() {
        let result = RequestLogQuery.process(
            logs: Self.logs,
            endpoints: [],
            methodFilter: nil,
            filterText: "",
            unmatchedOnly: true,
            sortField: .timestamp,
            sortAscending: true
        )
        #expect(result.contains { $0.path == "/account-summary" } == false)
    }

    @Test("The unmatched filter composes with the method filter")
    func composesWithMethodFilter() {
        let result = RequestLogQuery.process(
            logs: Self.logs + [Self.log(.post, "/also-not-mocked", status: 404, outcome: .unmatched)],
            endpoints: [],
            methodFilter: .post,
            filterText: "",
            unmatchedOnly: true,
            sortField: .timestamp,
            sortAscending: true
        )
        #expect(result.count == 1)
        #expect(result.first?.method == .post)
    }

    @Test("Free-text search finds requests by outcome name")
    func searchByOutcomeName() {
        let result = RequestLogQuery.process(
            logs: Self.logs,
            endpoints: [],
            methodFilter: nil,
            filterText: "unmatched",
            sortField: .timestamp,
            sortAscending: true
        )
        #expect(result.count == 2)
    }

    @Test("The unmatched count drives the toolbar badge")
    func countsUnmatched() {
        #expect(RequestLogQuery.unmatchedCount(logs: Self.logs) == 2)
        #expect(RequestLogQuery.unmatchedCount(logs: []) == 0)
    }

    @Test("The path offered for a new mock drops the query string")
    func mockablePathDropsQuery() {
        #expect(RequestLogQuery.mockablePath(from: "/inbox?page=2&unread=true") == "/inbox")
        #expect(RequestLogQuery.mockablePath(from: "/inbox") == "/inbox")
        #expect(RequestLogQuery.mockablePath(from: "/") == "/")
        // A query-only path would otherwise yield an empty string, which is not a valid route.
        #expect(RequestLogQuery.mockablePath(from: "?a=1") == "/")
    }
}
