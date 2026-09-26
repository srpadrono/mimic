import Foundation
import Testing
@testable import Domain
@testable import MockServerEngine

/// The serving path's guards against values that reached the store without passing a validator.
///
/// These are regression tests for a security review: each one reproduces something that used to
/// happen, and each failure mode is reachable from a project file the user did not write by hand —
/// an import, a shared fixture, a file edited outside the app.
///
/// Time-limited because every case here binds a real socket: a bind that never completes, or a
/// wait on traffic that never arrives, otherwise hangs the whole run with no indication of which
/// test is stuck. A minute is the finest granularity `.timeLimit` offers and is far above what
/// any of these needs — the point is a bound, not a deadline.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ServingHardeningTests {

    // MARK: - Status codes

    @Test("A status code outside 200...599 is clamped rather than trapping the process")
    func statusCodeIsClamped() {
        // Two crashes, one clamp. `HTTPResponseStatus(statusCode:)` funnels anything unrecognised
        // into `.custom(code: UInt(statusCode))`, and `UInt(_: Int)` traps on a negative; separately,
        // NIO's pipeline asserts when a 1xx head is followed by a body. The engine is embedded, so
        // either one took the whole app with it.
        #expect(VaporConfigurator.clampedStatusCode(-1) == 200)
        #expect(VaporConfigurator.clampedStatusCode(Int.min) == 200)
        #expect(VaporConfigurator.clampedStatusCode(0) == 200)
        #expect(VaporConfigurator.clampedStatusCode(100) == 200)
        #expect(VaporConfigurator.clampedStatusCode(199) == 200)
        #expect(VaporConfigurator.clampedStatusCode(100_000) == 599)
        #expect(VaporConfigurator.clampedStatusCode(Int.max) == 599)

        // Everything serveable passes through untouched.
        for code in [200, 201, 301, 404, 418, 500, 599] {
            #expect(VaporConfigurator.clampedStatusCode(code) == code)
        }
    }

    @Test("Serving an out-of-range status code answers instead of killing the server", arguments: [-1, 0, 100, 700])
    func outOfRangeStatusCodeIsServed(code: Int) async throws {
        let scenario = Scenario(name: "boom", statusCode: code, body: "{}")
        let endpoint = Endpoint(
            name: "boom",
            method: .get,
            path: "/boom",
            scenarios: [scenario],
            activeScenarioID: scenario.id
        )

        try await JourneyServingTests.withEngine(endpoints: [endpoint]) { engine, baseURL in
            let collector = LogCollector()
            let stream = engine.logStream
            let drain = Task { for await entry in stream { await collector.append(entry) } }
            defer { drain.cancel() }

            let port = try #require(baseURL.port)
            // Raw socket rather than URLSession: the point is that the *process is still alive* and
            // wrote one well-formed response, which a client that retries could disguise.
            let reply = try RawHTTPClient.send(method: "GET", path: "/boom", port: port)
            #expect(reply.isEmpty == false, "the server died instead of answering")
            #expect(reply.statusLine.hasPrefix("HTTP/1.1 "))
            #expect(reply.isTruncated == false)

            // Read the served status off the wire rather than restating the clamp, because asserting
            // the log against the *configured* value is exactly what let the two drift: the clamp
            // used to be applied only on the way out, so this scenario served 200 and the traffic
            // list said 0.
            try await collector.waitForCount(1)
            let logged = try #require(await collector.entries.first)
            #expect(logged.responseStatusCode == Self.servedStatusCode(reply.statusLine))
        }
    }

    @Test("The log records the status that was served, not the one that was configured")
    func logRecordsServedStatusCode() {
        // One clamp, two call sites: `response(for:)` and `makeLog`. The log is the half of a request
        // that is still readable once the request is over, so a log that reports a code no client ever
        // saw is worse than the bad code itself.
        #expect(Self.logEntry(statusCode: -1).responseStatusCode == 200)
        #expect(Self.logEntry(statusCode: 0).responseStatusCode == 200)
        #expect(Self.logEntry(statusCode: 100).responseStatusCode == 200)
        #expect(Self.logEntry(statusCode: 700).responseStatusCode == 599)

        // A serveable code is recorded exactly as configured.
        #expect(Self.logEntry(statusCode: 201).responseStatusCode == 201)
        #expect(Self.logEntry(statusCode: 503).responseStatusCode == 503)
    }

    @Test("Bodyless status codes suppress configured content on the wire and in the log", arguments: [204, 205, 304])
    func bodylessStatusesHaveNoContent(status: Int) async throws {
        let scenario = Scenario(name: "Bodyless", statusCode: status,
            headers: ["Content-Length": "999", "Transfer-Encoding": "chunked", "X-Safe": "kept"],
            body: "hi 🎉")
        let endpoint = Endpoint(name: "Bodyless", path: "/bodyless", scenarios: [scenario],
            activeScenarioID: scenario.id)

        try await JourneyServingTests.withEngine(endpoints: [endpoint]) { engine, baseURL in
            let collector = LogCollector()
            let drain = Task {
                for await entry in engine.logStream {
                    await collector.append(entry)
                    await engine.acknowledgeLog()
                }
            }
            defer { drain.cancel() }

            let port = try #require(baseURL.port)
            let reply = try RawHTTPClient.send(method: "GET", path: "/bodyless", port: port)
            #expect(Self.servedStatusCode(reply.statusLine) == status)
            #expect(reply.didClose)
            #expect(!reply.isTruncated)
            let separator = try #require(reply.raw.range(of: "\r\n\r\n"))
            #expect(reply.raw[separator.upperBound...].isEmpty)
            #expect(!reply.raw.lowercased().contains("\r\ntransfer-encoding:"))
            if status == 205 {
                #expect(reply.raw.lowercased().contains("\r\ncontent-length: 0\r\n"))
            } else {
                #expect(!reply.raw.lowercased().contains("\r\ncontent-length:"))
            }

            try await collector.waitForCount(1)
            let log = try #require(await collector.entries.first)
            #expect(log.responseStatusCode == status)
            #expect(log.responseBody == nil)
            #expect(!log.responseBodyTruncated)
            #expect(Self.header("Content-Length", in: log.responseHeaders) == (status == 205 ? "0" : nil))
            #expect(Self.header("Transfer-Encoding", in: log.responseHeaders) == nil)
            #expect(log.responseHeaders["X-Safe"] == "kept")
        }
    }

    @Test("GET and HEAD log the served framing and content", arguments: [HTTPMethod.get, .head])
    func responseFramingMatchesTheLog(method: HTTPMethod) async throws {
        let scenario = Scenario(name: "Framed", statusCode: 200,
            headers: ["Content-Length": "999", "Transfer-Encoding": "chunked"], body: "hi 🎉")
        let endpoint = Endpoint(name: "Framed", method: method, path: "/framed", scenarios: [scenario],
            activeScenarioID: scenario.id)

        try await JourneyServingTests.withEngine(endpoints: [endpoint]) { engine, baseURL in
            let collector = LogCollector()
            let drain = Task {
                for await entry in engine.logStream {
                    await collector.append(entry)
                    await engine.acknowledgeLog()
                }
            }
            defer { drain.cancel() }

            let port = try #require(baseURL.port)
            let reply = try RawHTTPClient.send(method: method.rawValue, path: "/framed", port: port)
            #expect(Self.servedStatusCode(reply.statusLine) == 200)
            #expect(reply.didClose)
            #expect(!reply.isTruncated)
            // The literal body is seven UTF-8 bytes. HEAD preserves that representation length
            // while sending no body; neither method may advertise the configured false framing.
            #expect(reply.raw.lowercased().contains("\r\ncontent-length: 7\r\n"))
            #expect(!reply.raw.lowercased().contains("\r\ntransfer-encoding:"))
            let separator = try #require(reply.raw.range(of: "\r\n\r\n"))
            #expect(String(reply.raw[separator.upperBound...]) == (method == .head ? "" : "hi 🎉"))

            try await collector.waitForCount(1)
            let log = try #require(await collector.entries.first)
            #expect(log.method == method)
            #expect(log.responseBody == (method == .head ? nil : "hi 🎉"))
            #expect(!log.responseBodyTruncated)
            #expect(Self.header("Content-Length", in: log.responseHeaders) == "7")
            #expect(Self.header("Transfer-Encoding", in: log.responseHeaders) == nil)
        }
    }

    @Test("HEAD transport failures close without a successful response", arguments: [NetworkFailure.connectionDrop, .timeout(holdMs: 30)])
    func headTransportFailureDoesNotBecomeSuccess(failure: NetworkFailure) async throws {
        let journey = Journey(name: "HEAD recovery", steps: [
            JourneyStep(name: "Fail", method: .head, path: "/head-failure", outcome: .networkFailure(failure)),
            JourneyStep(name: "Recover", method: .head, path: "/head-failure",
                outcome: .respond(JourneyResponse(statusCode: 204, body: "suppressed"))),
        ])

        try await JourneyServingTests.withEngine(journey: journey) { engine, baseURL in
            let collector = LogCollector()
            let drain = Task {
                for await entry in engine.logStream {
                    await collector.append(entry)
                    await engine.acknowledgeLog()
                }
            }
            defer { drain.cancel() }

            let port = try #require(baseURL.port)
            let failed = try RawHTTPClient.send(method: "HEAD", path: "/head-failure", port: port)
            #expect(failed.didClose, "the failure must close the socket, not wait for the read deadline")
            #expect(failed.isEmpty, "a HEAD status line is already a complete response: \(failed.raw)")
            #expect(failed.isTruncated)

            let recovered = try RawHTTPClient.send(method: "HEAD", path: "/head-failure", port: port)
            #expect(Self.servedStatusCode(recovered.statusLine) == 204)
            #expect(!recovered.isTruncated)
            try await collector.waitForCount(2)
            let logs = await collector.entries
            try #require(logs.count == 2)
            #expect(logs[0].method == .head)
            #expect(logs[0].responseStatusCode == nil)
            #expect(logs[0].failureLabel != nil)
            #expect(logs[0].responseBody == nil)
            #expect(logs[1].responseStatusCode == 204)
        }
    }

    // MARK: - Header injection

    @Test("The HTTP decoder rejects an excessive cumulative header list before serving a mock")
    func excessiveRequestHeadersAreRejected() async throws {
        let scenario = Scenario(name: "default", statusCode: 200, body: "{}")
        let endpoint = Endpoint(
            name: "header limit", method: .get, path: "/header-limit",
            scenarios: [scenario], activeScenarioID: scenario.id
        )

        try await JourneyServingTests.withEngine(endpoints: [endpoint]) { engine, baseURL in
            let collector = LogCollector()
            let drain = Task { for await entry in engine.logStream { await collector.append(entry) } }
            defer { drain.cancel() }
            let port = try #require(baseURL.port)
            // Each field is below the per-field limit, while their combined size exceeds
            // NIOHTTP1's 80 KiB list limit. The old decoder had no cumulative limit.
            let headers = (1...300).map { ("X-Pad-\($0)", String(repeating: "x", count: 512)) }
            let rejected = try RawHTTPClient.send(
                method: "GET", path: "/header-limit", port: port, additionalHeaders: headers
            )
            #expect(!rejected.statusLine.hasPrefix("HTTP/1.1 200"))

            // A malformed peer must not take the embedded server down for the next client.
            let normal = try RawHTTPClient.send(method: "GET", path: "/header-limit", port: port)
            #expect(normal.statusLine.hasPrefix("HTTP/1.1 200"))
            try await collector.waitForCount(1)
            let firstLog = try #require(await collector.entries.first)
            #expect(firstLog.requestHeaders["X-Pad-300"] == nil,
                    "the excessive-header request reached application logging")
        }
    }

    @Test("A header value containing CRLF cannot split the response")
    func crlfHeaderValueIsDropped() async throws {
        let scenario = Scenario(
            name: "injected",
            statusCode: 200,
            headers: [
                "X-Test": "a\r\nX-Injected: yes\r\nSet-Cookie: evil=1",
                "X-Safe": "kept",
            ],
            body: "{}"
        )
        let endpoint = Endpoint(
            name: "injected",
            method: .get,
            path: "/inject",
            scenarios: [scenario],
            activeScenarioID: scenario.id
        )

        try await JourneyServingTests.withEngine(endpoints: [endpoint]) { engine, baseURL in
            let collector = LogCollector()
            let stream = engine.logStream
            let drain = Task { for await entry in stream { await collector.append(entry) } }
            defer { drain.cancel() }

            let port = try #require(baseURL.port)
            let reply = try RawHTTPClient.send(method: "GET", path: "/inject", port: port)

            #expect(reply.raw.contains("X-Injected") == false, "the injected header reached the wire")
            #expect(reply.raw.contains("Set-Cookie") == false, "the injected cookie reached the wire")
            #expect(reply.raw.contains("X-Test") == false, "the malformed header should be dropped whole")
            // Dropping the bad one must not cost the good ones.
            #expect(reply.raw.contains("X-Safe: kept"))

            // And the log has to say the same thing the wire did. It used to list `X-Test` among the
            // headers the client received, which is the one reading a developer cannot check for
            // themselves — the response is gone by the time they open the panel.
            try await collector.waitForCount(1)
            let logged = try #require(await collector.entries.first)
            #expect(logged.responseHeaders["X-Test"] == nil, "a header that never went out was logged as sent")
            #expect(logged.responseHeaders["X-Safe"] == "kept")
        }
    }

    @Test("The log records the headers that were written, not the ones that were dropped")
    func logOmitsDroppedHeaders() {
        let headers = Self.logEntry(statusCode: 200, headers: [
            "X-Test": "a\r\nX-Injected: yes",
            "X Space": "v",
            "X-Safe": "kept",
        ]).responseHeaders

        // Both halves of the grammar, because `response(for:)` drops on both: a value that can end
        // the header line early, and a name that is not a token.
        #expect(headers["X-Test"] == nil)
        #expect(headers["X Space"] == nil)
        #expect(headers["X-Safe"] == "kept")

        // The content type the server chose is part of what the client received, so it stays.
        #expect(headers["Content-Type"] == Scenario.ContentType.json.rawValue)
    }

    @Test("A scenario's own Content-Type replaces the logged default whatever its spelling")
    func logMatchesTheWireOnContentTypeCase() {
        // The wire is built through `replaceOrAdd`, which keys headers case-insensitively, so a
        // scenario header spelled `content-type` serves exactly one Content-Type. The log used to
        // copy scenario headers by exact key over its seeded "Content-Type", recording two
        // disagreeing values — one of which no client ever received.
        let headers = Self.logEntry(statusCode: 200, headers: [
            "content-type": "application/xml",
        ]).responseHeaders

        #expect(headers.count == 2, "the log includes one content type and the served byte count")
        #expect(headers["content-type"] == "application/xml")
        #expect(headers["Content-Type"] == nil, "the replaced spelling must not linger beside the scenario's")
        #expect(Self.header("Content-Length", in: headers) == "2")
    }

    @Test("Header names and values are held to the RFC 9110 grammar")
    func headerValidation() {
        #expect(EndpointValidator.isValidHeader(name: "X-Request-Id", value: "abc123"))
        #expect(EndpointValidator.isValidHeader(name: "Cache-Control", value: "no-store, max-age=0"))

        // Values: the three characters that can end a header line early.
        #expect(EndpointValidator.isValidHeader(name: "X", value: "a\r\nB: c") == false)
        #expect(EndpointValidator.isValidHeader(name: "X", value: "a\nB: c") == false)
        #expect(EndpointValidator.isValidHeader(name: "X", value: "a\rB: c") == false)
        #expect(EndpointValidator.isValidHeader(name: "X", value: "a\u{0}b") == false)

        // Names: anything outside `tchar`, including the separators that split a header block.
        #expect(EndpointValidator.isValidHeader(name: "", value: "v") == false)
        #expect(EndpointValidator.isValidHeader(name: "X Test", value: "v") == false)
        #expect(EndpointValidator.isValidHeader(name: "X:Test", value: "v") == false)
        #expect(EndpointValidator.isValidHeader(name: "X\r\nY", value: "v") == false)
    }

    // MARK: - Log growth

    @Test("Request bodies are capped in the log, not only response bodies")
    func requestBodyIsCapped() {
        // The route collects up to 10 MB and the log holds a thousand entries; uncapped, that is ten
        // gigabytes of live memory driven entirely by what the app under test posts.
        let oversized = String(repeating: "x", count: RequestLog.maxLoggedBodyBytes + 4096)
        let log = VaporConfigurator.makeLog(
            incoming: IncomingRequest(method: .post, path: "/upload", headers: [:], body: oversized),
            resolved: ResolvedResponse(
                statusCode: 200,
                headers: [:],
                contentType: .json,
                body: "{}",
                delayMs: 0,
                matchedEndpointID: nil,
                matchedScenarioID: nil
            )
        )

        let bodyBytes = log.requestBody?.utf8.count ?? 0
        #expect(bodyBytes <= RequestLog.maxLoggedBodyBytes)
        #expect(bodyBytes > 0, "the body is capped, not discarded")
    }

    @Test("Capping a body never splits a multi-byte character")
    func cappingRespectsScalarBoundaries() {
        // "🎉" is four UTF-8 bytes. Aligning the payload so the cap lands mid-emoji is the case that
        // silently produced U+FFFD before.
        let filler = String(repeating: "a", count: RequestLog.maxLoggedBodyBytes - 2)
        let (capped, truncated) = RequestLog.cappedBody(filler + "🎉🎉")

        #expect(truncated)
        #expect(capped == filler, "the incomplete emoji must be removed without altering the complete prefix")
    }

    // MARK: - Redaction

    @Test("Credential headers are redacted by name, case-insensitively")
    func redactionCoversTheUsualHeaders() {
        let log = RequestLog(
            method: .get,
            path: "/",
            requestHeaders: [
                "authorization": "Bearer secret",
                "Cookie": "session=abc",
                "X-API-Key": "k-123",
                "Accept": "application/json",
            ],
            responseHeaders: ["set-cookie": "session=rotated", "Content-Type": "application/json"]
        )

        let redacted = log.redactingCredentials()
        #expect(redacted.requestHeaders["authorization"] == RequestLog.redactionPlaceholder)
        #expect(redacted.requestHeaders["Cookie"] == RequestLog.redactionPlaceholder)
        #expect(redacted.requestHeaders["X-API-Key"] == RequestLog.redactionPlaceholder)
        #expect(redacted.responseHeaders["set-cookie"] == RequestLog.redactionPlaceholder)

        // Everything else is untouched, including the redacted headers' names.
        #expect(redacted.requestHeaders["Accept"] == "application/json")
        #expect(redacted.responseHeaders["Content-Type"] == "application/json")
        #expect(redacted.path == log.path)
    }

    // MARK: - Helpers

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The log entry the engine would write for a response resolved this way, without standing a
    /// server up — these assertions are about what `makeLog` records, not about routing.
    private static func logEntry(statusCode: Int, headers: [String: String] = [:]) -> RequestLog {
        VaporConfigurator.makeLog(
            incoming: IncomingRequest(method: .get, path: "/thing"),
            resolved: ResolvedResponse(
                statusCode: statusCode,
                headers: headers,
                contentType: .json,
                body: "{}",
                delayMs: 0,
                matchedEndpointID: nil,
                matchedScenarioID: nil
            )
        )
    }

    /// The status a client actually read, taken from `HTTP/1.1 200 OK` rather than from the scenario.
    private static func servedStatusCode(_ statusLine: String) -> Int? {
        let fields = statusLine.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return Int(fields[1])
    }
}
