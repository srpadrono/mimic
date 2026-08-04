import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in FoundationNetworking on Linux, not Foundation. Without this the CLI and the
// tests that speak HTTP do not compile there — and CI runs on Linux.
import FoundationNetworking
#endif
import Testing
@testable import Domain
@testable import MockServerEngine

/// The serving side against traffic with the awkward properties real clients produce, rather than
/// the tidy requests a test tends to write.
///
/// Same motivation as the import audit: the bugs that reached users were not in the logic, they were
/// in the assumptions about what arrives on the wire.
@Suite(.serialized)
struct RealTrafficTests {

    static func endpoint(
        _ method: HTTPMethod,
        _ path: String,
        status: Int = 200,
        headers: [String: String] = [:],
        body: String? = nil,
        contentType: Scenario.ContentType = .json
    ) -> Endpoint {
        let scenario = Scenario(
            name: "Default",
            statusCode: status,
            headers: headers,
            body: body,
            bodyContentType: contentType
        )
        return Endpoint(
            name: "\(method.rawValue) \(path)",
            method: method,
            path: path,
            scenarios: [scenario],
            activeScenarioID: scenario.id
        )
    }

    // MARK: - Bodies

    @Test("A non-ASCII body arrives byte-for-byte")
    func unicodeBodySurvivesTheWire() async throws {
        // Encoding bugs here are silent: the status is right, the payload is subtly wrong, and a test
        // that only asserts the status never notices.
        let payload = #"{"name":"Ünïcodé ✅ 日本語","price":"€10","emoji":"🎉"}"#
        try await JourneyServingTests.withEngine(
            endpoints: [Self.endpoint(.get, "/unicode", body: payload)]
        ) { _, baseURL in
            let reply = try await JourneyServingTests.call("GET", "unicode", baseURL: baseURL, session: JourneyServingTests.session())
            #expect(reply.body == payload)
        }
    }

    @Test("A large body is served whole")
    func largeBodyIsServedWhole() async throws {
        // Roughly a megabyte of JSON — big enough to span buffers, which is where truncation hides.
        let items = (0..<20_000).map { #"{"id":\#($0),"name":"item-\#($0)"}"# }.joined(separator: ",")
        let payload = "{\"items\":[\(items)]}"

        try await JourneyServingTests.withEngine(
            endpoints: [Self.endpoint(.get, "/big", body: payload)]
        ) { _, baseURL in
            let reply = try await JourneyServingTests.call("GET", "big", baseURL: baseURL, session: JourneyServingTests.session(timeout: 30))
            #expect(reply.body.utf8.count == payload.utf8.count)
            #expect(reply.body.hasSuffix("]}"), "a truncated body would lose the closing brackets")
        }
    }

    @Test("A response with no body is served as empty, not as null text")
    func emptyBodyIsEmpty() async throws {
        try await JourneyServingTests.withEngine(
            endpoints: [Self.endpoint(.get, "/nothing", status: 204, body: nil)]
        ) { _, baseURL in
            let reply = try await JourneyServingTests.call("GET", "nothing", baseURL: baseURL, session: JourneyServingTests.session())
            #expect(reply.status == 204)
            #expect(reply.body.isEmpty)
        }
    }

    // MARK: - Paths

    @Test("A percent-encoded path segment matches the route it encodes")
    func percentEncodedPath() async throws {
        try await JourneyServingTests.withEngine(
            endpoints: [Self.endpoint(.get, "/things/:id", body: #"{"ok":true}"#)]
        ) { _, baseURL in
            // Real clients encode ids containing spaces or slashes.
            let reply = try await JourneyServingTests.call("GET", "things/hello%20world", baseURL: baseURL, session: JourneyServingTests.session())
            #expect(reply.status == 200)
        }
    }

    @Test("A query string never affects which route matches")
    func queryStringIgnored() async throws {
        try await JourneyServingTests.withEngine(
            endpoints: [Self.endpoint(.get, "/search", body: #"{"results":[]}"#)]
        ) { _, baseURL in
            var request = URLRequest(url: baseURL.appendingPathComponent("search")
                .appending(queryItems: [URLQueryItem(name: "q", value: "a b&c"), URLQueryItem(name: "page", value: "2")]))
            request.httpMethod = "GET"
            let (data, response) = try await JourneyServingTests.session().data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self) == #"{"results":[]}"#)
        }
    }

    @Test("A deeply nested path still resolves to the most specific route")
    func deepPathSpecificity() async throws {
        try await JourneyServingTests.withEngine(endpoints: [
            Self.endpoint(.get, "/a/:b/c/:d/e", status: 201),
            Self.endpoint(.get, "/a/:b/c/:d/:e", status: 202),
        ]) { _, baseURL in
            let reply = try await JourneyServingTests.call("GET", "a/1/c/2/e", baseURL: baseURL, session: JourneyServingTests.session())
            #expect(reply.status == 201, "the literal final segment is more specific than a wildcard")
        }
    }

    // MARK: - Methods and headers

    @Test("A HEAD request gets the status and headers without a body")
    func headRequest() async throws {
        try await JourneyServingTests.withEngine(
            endpoints: [Self.endpoint(.head, "/thing", status: 200, headers: ["X-Trace": "t"], body: "should not be sent")]
        ) { _, baseURL in
            var request = URLRequest(url: baseURL.appendingPathComponent("thing"))
            request.httpMethod = "HEAD"
            let (data, response) = try await JourneyServingTests.session().data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            // HTTP forbids a body on a HEAD response; sending one confuses well-behaved clients.
            #expect(data.isEmpty)
        }
    }

    @Test("A request body does not have to be JSON, or valid anything")
    func arbitraryRequestBody() async throws {
        try await JourneyServingTests.withEngine(
            endpoints: [Self.endpoint(.post, "/upload", status: 202, body: #"{"accepted":true}"#)]
        ) { _, baseURL in
            var request = URLRequest(url: baseURL.appendingPathComponent("upload"))
            request.httpMethod = "POST"
            request.httpBody = Data([0x00, 0xFF, 0xFE, 0x01, 0x02])
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

            let (_, response) = try await JourneyServingTests.session().data(for: request)
            // Binary that is not valid UTF-8 must not break matching or logging.
            #expect((response as? HTTPURLResponse)?.statusCode == 202)
        }
    }

    @Test("A header the scenario sets replaces the default rather than duplicating it")
    func scenarioHeaderWins() async throws {
        try await JourneyServingTests.withEngine(endpoints: [
            Self.endpoint(.get, "/xml", headers: ["Content-Type": "application/xml"], body: "<x/>", contentType: .json)
        ]) { _, baseURL in
            let reply = try await JourneyServingTests.call("GET", "xml", baseURL: baseURL, session: JourneyServingTests.session())
            // The regression this pins: appending produced two Content-Type headers and left the
            // client to guess which applied.
            #expect(reply.headers["Content-Type"] == "application/xml")
        }
    }

    // MARK: - Load

    @Test("Many concurrent requests are all answered correctly")
    func concurrentLoad() async throws {
        try await JourneyServingTests.withEngine(endpoints: [
            Self.endpoint(.get, "/a", status: 200, body: "a"),
            Self.endpoint(.get, "/b", status: 201, body: "b"),
            Self.endpoint(.get, "/c", status: 202, body: "c"),
        ]) { _, baseURL in
            let session = JourneyServingTests.session(timeout: 30)
            let routes = [("a", 200), ("b", 201), ("c", 202)]

            let results = try await withThrowingTaskGroup(of: (String, Int).self) { group in
                for _ in 0..<40 {
                    for (path, _) in routes {
                        group.addTask {
                            let reply = try await JourneyServingTests.call("GET", path, baseURL: baseURL, session: session)
                            return (reply.body, reply.status)
                        }
                    }
                }
                var collected: [(String, Int)] = []
                for try await result in group { collected.append(result) }
                return collected
            }

            #expect(results.count == 120)
            // Every response must match its own route — a shared-state bug shows up here as a body
            // paired with the wrong status.
            for (body, status) in results {
                let expected = routes.first { $0.0 == body }?.1
                #expect(status == expected, "body \(body) came back with status \(status)")
            }
        }
    }
}
