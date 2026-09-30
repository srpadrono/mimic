import Foundation
import Testing
import Domain
@testable import AppFeatures
@testable import RequestLogFeature

/// The request log's Errors scope, its name-aware filter, and the figures the Duration and Size
/// columns and the inspector's metrics line draw.
@Suite("Request log query")
@MainActor
struct RequestLogQueryTests {

    private static func log(
        path: String,
        status: Int?,
        at seconds: TimeInterval,
        method: HTTPMethod = .get,
        failureLabel: String? = nil,
        outcome: RequestOutcome = .endpoint,
        endpointID: UUID? = nil,
        scenarioID: UUID? = nil
    ) -> RequestLog {
        RequestLog(
            timestamp: Date(timeIntervalSince1970: seconds),
            method: method,
            path: path,
            matchedEndpointID: endpointID,
            matchedScenarioID: scenarioID,
            responseStatusCode: status,
            failureLabel: failureLabel,
            outcome: outcome
        )
    }

    private func process(
        _ logs: [RequestLog],
        endpoints: [Endpoint] = [],
        method: HTTPMethod? = nil,
        text: String = "",
        unmatchedOnly: Bool = false,
        errorsOnly: Bool = false
    ) -> [String] {
        RequestLogQuery.process(
            logs: logs,
            endpoints: endpoints,
            methodFilter: method,
            filterText: text,
            unmatchedOnly: unmatchedOnly,
            errorsOnly: errorsOnly,
            sortField: .timestamp,
            sortAscending: true
        )
        .map(\.path)
    }

    // MARK: - Errors

    @Test("An error is a 4xx or 5xx answer, or no answer at all")
    func classifiesErrors() {
        #expect(RequestLogQuery.isError(Self.log(path: "/ok", status: 200, at: 0)) == false)
        #expect(RequestLogQuery.isError(Self.log(path: "/redirect", status: 399, at: 0)) == false)
        #expect(RequestLogQuery.isError(Self.log(path: "/missing", status: 400, at: 0)))
        #expect(RequestLogQuery.isError(Self.log(path: "/boom", status: 503, at: 0)))
        #expect(RequestLogQuery.isError(
            Self.log(path: "/dropped", status: nil, at: 0, failureLabel: "connection-drop")
        ))
    }

    @Test("The Errors scope keeps failures and error answers, and the count agrees")
    func errorsScopeFiltersAndCounts() {
        let logs = [
            Self.log(path: "/ok", status: 200, at: 100),
            Self.log(path: "/not-mocked", status: 404, at: 200, outcome: .unmatched),
            Self.log(path: "/created", status: 201, at: 300, method: .post),
            Self.log(path: "/boom", status: 500, at: 400, method: .post),
            Self.log(path: "/dropped", status: nil, at: 500, failureLabel: "timeout(30000ms)"),
        ]

        #expect(process(logs, errorsOnly: true) == ["/not-mocked", "/boom", "/dropped"])
        #expect(RequestLogQuery.errorCount(logs: logs) == 3)
        #expect(RequestLogQuery.errorCount(logs: []) == 0)
        // Composes with the method filter like every other predicate.
        #expect(process(logs, method: .post, errorsOnly: true) == ["/boom"])
        // Off, nothing is removed.
        #expect(process(logs).count == 5)
    }

    // MARK: - Text filter

    @Test("The filter also finds a request by the endpoint or scenario that answered it")
    func textFilterMatchesResolvedNames() {
        let expired = Scenario(name: "Expired card", statusCode: 402)
        let charge = Endpoint(
            name: "Charge summary",
            method: .post,
            path: "/v2/pay",
            scenarios: [expired],
            activeScenarioID: expired.id
        )
        let logs = [
            Self.log(path: "/v2/pay", status: 402, at: 100, method: .post,
                     endpointID: charge.id, scenarioID: expired.id),
            Self.log(path: "/health", status: 200, at: 200),
        ]

        // Neither word is in the path, the status or the outcome label; only the names hold them.
        #expect(process(logs, endpoints: [charge], text: "summary") == ["/v2/pay"])
        #expect(process(logs, endpoints: [charge], text: "EXPIRED") == ["/v2/pay"])
        // Without the endpoint to resolve against, the names are unknown and nothing matches.
        #expect(process(logs, text: "summary").isEmpty)
        // The path rules still apply.
        #expect(process(logs, endpoints: [charge], text: "health") == ["/health"])
    }

    // MARK: - Figures

    @Test("Durations read in milliseconds, then seconds from one second up")
    func formatsDurations() {
        #expect(RequestLogQuery.formattedDuration(0) == "0 ms")
        #expect(RequestLogQuery.formattedDuration(8) == "8 ms")
        #expect(RequestLogQuery.formattedDuration(999) == "999 ms")
        #expect(RequestLogQuery.formattedDuration(1_000) == "1.0 s")
        #expect(RequestLogQuery.formattedDuration(12_340) == "12.3 s")
    }

    @Test("Byte counts read in B, KB and MB")
    func formatsBytes() {
        #expect(RequestLogQuery.formattedBytes(0) == "0 B")
        #expect(RequestLogQuery.formattedBytes(1_023) == "1023 B")
        #expect(RequestLogQuery.formattedBytes(1_024) == "1.0 KB")
        #expect(RequestLogQuery.formattedBytes(1_536) == "1.5 KB")
        #expect(RequestLogQuery.formattedBytes(1_048_576) == "1.0 MB")
    }

    @Test("A response's size comes from its logged body, else its Content-Length")
    func formatsResponseSize() {
        let whole = RequestLog(method: .get, path: "/a", responseStatusCode: 200, responseBody: "abc")
        #expect(RequestLogQuery.formattedSize(for: whole) == "3 B")

        // A truncated body is only a prefix; the declared length is the real size.
        let truncated = RequestLog(
            method: .get, path: "/b", responseStatusCode: 200,
            responseHeaders: ["content-length": " 70000 "],
            responseBody: "prefix", responseBodyTruncated: true
        )
        #expect(RequestLogQuery.formattedSize(for: truncated) == "68.4 KB")

        let binary = RequestLog(
            method: .get, path: "/c", responseBodyIsBinary: true, responseStatusCode: 200,
            responseHeaders: ["Content-Length": "2048"]
        )
        #expect(RequestLogQuery.formattedSize(for: binary) == "2.0 KB")

        // Neither a whole body nor a length: the size is unknown, not zero.
        let truncatedUnsized = RequestLog(
            method: .get, path: "/d", responseStatusCode: 200,
            responseBody: "prefix", responseBodyTruncated: true
        )
        let binaryUnsized = RequestLog(
            method: .get, path: "/e", responseBodyIsBinary: true, responseStatusCode: 200
        )
        #expect(RequestLogQuery.formattedSize(for: truncatedUnsized) == nil)
        #expect(RequestLogQuery.formattedSize(for: binaryUnsized) == nil)

        // No status, no body, no length: no response arrived, so there is no size, not a zero one.
        let failed = RequestLog(
            method: .post, path: "/g", failureLabel: "timeout(30000ms)", outcome: .proxyFailure
        )
        let unanswered = RequestLog(method: .get, path: "/h")
        #expect(RequestLogQuery.formattedSize(for: failed) == nil)
        #expect(RequestLogQuery.formattedSize(for: unanswered) == nil)

        // An answer with an empty body is genuinely zero bytes.
        let noContent = RequestLog(method: .delete, path: "/f", responseStatusCode: 204, responseBody: "")
        #expect(RequestLogQuery.formattedSize(for: noContent) == "0 B")
    }
}
