import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in FoundationNetworking on Linux, not Foundation. Without this the CLI and the
// tests that speak HTTP do not compile there — and CI runs on Linux.
import FoundationNetworking
#endif
import Testing
@testable import Domain
@testable import MockServerEngine

/// The root path, `/`, which the engine used to hand straight back to Vapor.
///
/// Every route was registered as `**`, and RoutingKit only remembers a catchall *while walking the
/// request's path components*. `GET /` has none, so the search ended on the method node, found no
/// output, and fell through to Vapor's own not-found responder — Mimic's handler was never called.
/// Two things followed from that, and the second is the worse one: an endpoint configured at `/`
/// could not be served, and a request to `/` produced no `RequestLog` at all, so traffic vanished
/// instead of being counted as unmatched. An app that under-reports what arrived is worse than one
/// that answers wrongly, because there is nothing on screen to debug.
///
/// `/` is not an exotic path: it is what a browser sends for `http://localhost:8080`, what a health
/// check hits, and what an API gateway mock roots itself at.
@Suite(.serialized)
struct RootPathServingTests {

    /// The root URL as a real client emits it — `appendingPathComponent("")` cannot express `/`, and
    /// the bug lived exactly in that gap between "a path" and "no path".
    static func rootURL(_ baseURL: URL) throws -> URL {
        try #require(URL(string: baseURL.absoluteString + "/"))
    }

    /// Header lookup that does not depend on how a platform's Foundation cases the keys — Linux and
    /// Darwin disagree, and CI runs the former.
    static func header(_ name: String, in reply: JourneyServingTests.Reply) -> String? {
        reply.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func call(
        _ method: String,
        url: URL,
        session: URLSession
    ) async throws -> JourneyServingTests.Reply {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return JourneyServingTests.Reply(
            status: http.statusCode,
            body: String(decoding: data, as: UTF8.self),
            headers: headers
        )
    }

    // MARK: - Serving the root

    @Test("An endpoint configured at / is served with its own status and body")
    func rootEndpointIsServed() async throws {
        let endpoint = JourneyServingTests.endpoint(.get, "/", 201, body: #"{"root":true}"#)

        try await JourneyServingTests.withEngine(endpoints: [endpoint]) { _, baseURL in
            let reply = try await Self.call(
                "GET",
                url: Self.rootURL(baseURL),
                session: JourneyServingTests.session()
            )
            #expect(reply.status == 201)
            #expect(reply.body == #"{"root":true}"#)
        }
    }

    @Test("The root endpoint answers the bare origin a browser sends, with no trailing slash typed")
    func rootEndpointAnswersBareOrigin() async throws {
        // `http://localhost:8080` in an address bar still puts `GET / HTTP/1.1` on the wire. The
        // request the engine has to handle is identical; only the URL the developer typed differs.
        let endpoint = JourneyServingTests.endpoint(.get, "/", 200, body: "index")

        try await JourneyServingTests.withEngine(endpoints: [endpoint]) { _, baseURL in
            let reply = try await Self.call("GET", url: baseURL, session: JourneyServingTests.session())
            #expect(reply.status == 200)
            #expect(reply.body == "index")
        }
    }

    @Test("Methods other than GET are served at the root too", arguments: [
        HTTPMethod.post, .put, .patch, .delete,
    ])
    func rootIsServedForEveryMethod(method: HTTPMethod) async throws {
        // The root registration is inside the same per-method loop as the catchall; this pins that it
        // stays there rather than being added for GET alone.
        let endpoint = JourneyServingTests.endpoint(method, "/", 202, body: "root-\(method.rawValue)")

        try await JourneyServingTests.withEngine(endpoints: [endpoint]) { _, baseURL in
            let reply = try await Self.call(
                method.rawValue,
                url: Self.rootURL(baseURL),
                session: JourneyServingTests.session()
            )
            #expect(reply.status == 202)
            #expect(reply.body == "root-\(method.rawValue)")
        }
    }

    @Test("HEAD and OPTIONS reach the root as well", arguments: [HTTPMethod.head, .options])
    func bodylessMethodsReachTheRoot(method: HTTPMethod) async throws {
        // `HEAD /` is what a health check sends and `OPTIONS /` what a browser preflights with, so
        // both are root traffic a mock server sees in practice. Read off the socket because
        // URLSession discards a HEAD body and would hide a malformed one.
        let endpoint = JourneyServingTests.endpoint(method, "/", 204, body: "")

        try await JourneyServingTests.withEngine(endpoints: [endpoint]) { _, baseURL in
            let port = try #require(baseURL.port)
            let reply = try RawHTTPClient.send(method: method.rawValue, path: "/", port: port)
            #expect(reply.statusLine.hasPrefix("HTTP/1.1 204"))
        }
    }

    // MARK: - The unmatched root

    @Test("An unmatched request to / is answered by Mimic's own 404, not Vapor's")
    func unmatchedRootGetsMimicsNotFound() async throws {
        try await JourneyServingTests.withEngine(
            endpoints: [JourneyServingTests.endpoint(.get, "/inbox", 200)]
        ) { _, baseURL in
            let reply = try await Self.call(
                "GET",
                url: Self.rootURL(baseURL),
                session: JourneyServingTests.session()
            )

            #expect(reply.status == 404)
            // The distinguishing detail from the bug report: Vapor's not-found is
            // `{"error":true,"reason":"Not Found"}` as JSON. Mimic's says what it means, in text.
            #expect(reply.body == "No mock endpoint matched.")
            #expect(Self.header("Content-Type", in: reply)?.hasPrefix("text/plain") == true)
        }
    }

    @Test("An unmatched request to / is logged as unmatched rather than disappearing")
    func unmatchedRootIsLogged() async throws {
        // The half of the bug that mattered most: the request never reached the handler, so it was
        // absent from the request log *and* from the unmatched count. The window said nothing had
        // arrived while the client was being 404'd.
        try await JourneyServingTests.withEngine(
            endpoints: [JourneyServingTests.endpoint(.get, "/inbox", 200)]
        ) { engine, baseURL in
            let collector = LogCollector()
            let stream = engine.logStream
            let drain = Task { for await entry in stream { await collector.append(entry) } }
            defer { drain.cancel() }

            _ = try await Self.call("GET", url: Self.rootURL(baseURL), session: JourneyServingTests.session())

            try await collector.waitForCount(1)
            let logged = try #require(await collector.entries.first)

            #expect(logged.path == "/")
            #expect(logged.method == .get)
            #expect(logged.outcome == .unmatched)
            #expect(logged.outcome.isMissingConfiguration)
            #expect(logged.responseStatusCode == 404)
        }
    }

    @Test("A served root request is logged as an endpoint hit")
    func servedRootIsLogged() async throws {
        try await JourneyServingTests.withEngine(
            endpoints: [JourneyServingTests.endpoint(.get, "/", 200, body: "index")]
        ) { engine, baseURL in
            let collector = LogCollector()
            let stream = engine.logStream
            let drain = Task { for await entry in stream { await collector.append(entry) } }
            defer { drain.cancel() }

            _ = try await Self.call("GET", url: Self.rootURL(baseURL), session: JourneyServingTests.session())

            try await collector.waitForCount(1)
            let logged = try #require(await collector.entries.first)

            #expect(logged.path == "/")
            #expect(logged.outcome == .endpoint)
            #expect(logged.responseStatusCode == 200)
            #expect(logged.responseBody == "index")
        }
    }

    // MARK: - Isolation between / and everything else

    @Test("/ and /something answer for themselves and never for each other")
    func rootAndChildDoNotShadowEachOther() async throws {
        try await JourneyServingTests.withEngine(endpoints: [
            JourneyServingTests.endpoint(.get, "/", 200, body: "root"),
            JourneyServingTests.endpoint(.get, "/something", 201, body: "something"),
        ]) { _, baseURL in
            let session = JourneyServingTests.session()

            let root = try await Self.call("GET", url: Self.rootURL(baseURL), session: session)
            #expect(root.status == 200)
            #expect(root.body == "root")

            let child = try await JourneyServingTests.call("GET", "something", baseURL: baseURL, session: session)
            #expect(child.status == 201)
            #expect(child.body == "something")

            // A deeper path is nobody's: adding the root route must not turn it into a catch-all.
            let deeper = try await JourneyServingTests.call("GET", "something/else", baseURL: baseURL, session: session)
            #expect(deeper.status == 404)
            #expect(deeper.body == "No mock endpoint matched.")
        }
    }

    @Test("A root endpoint does not answer for a child path")
    func rootDoesNotSwallowChildren() async throws {
        try await JourneyServingTests.withEngine(
            endpoints: [JourneyServingTests.endpoint(.get, "/", 200, body: "root")]
        ) { _, baseURL in
            let reply = try await JourneyServingTests.call(
                "GET",
                "something",
                baseURL: baseURL,
                session: JourneyServingTests.session()
            )
            #expect(reply.status == 404)
            #expect(reply.body == "No mock endpoint matched.")
        }
    }

    @Test("A child endpoint does not answer for the root")
    func childDoesNotAnswerRoot() async throws {
        try await JourneyServingTests.withEngine(
            endpoints: [JourneyServingTests.endpoint(.get, "/something", 200, body: "something")]
        ) { _, baseURL in
            let reply = try await Self.call(
                "GET",
                url: Self.rootURL(baseURL),
                session: JourneyServingTests.session()
            )
            #expect(reply.status == 404)
            #expect(reply.body == "No mock endpoint matched.")
        }
    }

    // MARK: - On the wire

    @Test("The exact bytes for GET / are Mimic's response, read off the socket")
    func rootResponseOnTheWire() async throws {
        // URLSession normalises URLs on the way out; this makes the request the way the bug report
        // did — a literal `GET / HTTP/1.1` — so nothing between the test and the server can turn `/`
        // into something else.
        try await JourneyServingTests.withEngine(
            endpoints: [JourneyServingTests.endpoint(.get, "/", 200, body: "index")]
        ) { _, baseURL in
            let port = try #require(baseURL.port)
            let reply = try RawHTTPClient.send(method: "GET", path: "/", port: port)

            #expect(reply.statusLine.hasPrefix("HTTP/1.1 200"))
            #expect(reply.raw.hasSuffix("index"))
            #expect(reply.isTruncated == false)
        }
    }

    @Test("An unmatched GET / on the wire is Mimic's plain-text 404, not Vapor's JSON one")
    func unmatchedRootOnTheWire() async throws {
        try await JourneyServingTests.withEngine { _, baseURL in
            let port = try #require(baseURL.port)
            let reply = try RawHTTPClient.send(method: "GET", path: "/", port: port)

            #expect(reply.statusLine.hasPrefix("HTTP/1.1 404"))
            #expect(reply.raw.contains("text/plain"))
            #expect(reply.raw.hasSuffix("No mock endpoint matched."))
            // The signature of the regression: Vapor's error middleware answers in JSON.
            #expect(reply.raw.contains(#"{"error":true"#) == false, "Vapor answered instead of Mimic")
        }
    }
}
