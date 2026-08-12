import Foundation
import Testing
@testable import Domain
@testable import SpecImport

/// Import tested against what a *real* server and a *real* browser produce, rather than fixtures
/// written to match the implementation.
///
/// This suite exists because of a specific miss: `Content-Encoding: gzip` — present on essentially
/// every real capture — was copied onto imported mocks, so a mock served plain JSON while announcing
/// it was compressed and every client failed. The synthetic fixtures never carried the header, so
/// nothing caught it. Each case below is a property of genuine traffic that a hand-written fixture
/// tends not to have.
@Suite("Import against realistic captures")
struct RealCaptureTests {

    static func har(entries: String) -> Data {
        Data("""
        { "log": { "version": "1.2", "creator": { "name": "browser", "version": "1" },
          "entries": [\(entries)] } }
        """.utf8)
    }

    static func entry(
        method: String = "GET",
        url: String = "https://api.test/v1/things",
        status: Int = 200,
        headers: String,
        mimeType: String = "application/json",
        text: String = "{\\\"ok\\\":true}",
        extraContent: String = ""
    ) -> String {
        """
        { "request": { "method": "\(method)", "url": "\(url)" },
          "response": { "status": \(status), "headers": [\(headers)],
            "content": { "mimeType": "\(mimeType)", "text": "\(text)"\(extraContent) } } }
        """
    }

    // MARK: - What real servers send

    @Test("A capture with the full header set a real CDN sends imports cleanly")
    func realWorldHeaderSet() async throws {
        // Copied from the shape of an actual CDN response: compression, caching, tracing, security,
        // and framing all mixed together.
        let headers = """
        { "name": "content-encoding", "value": "br" },
        { "name": "content-length", "value": "1234" },
        { "name": "content-type", "value": "application/json; charset=utf-8" },
        { "name": "cache-control", "value": "public, max-age=60" },
        { "name": "etag", "value": "W/\\"abc123\\"" },
        { "name": "vary", "value": "Accept-Encoding, Origin" },
        { "name": "strict-transport-security", "value": "max-age=63072000" },
        { "name": "x-request-id", "value": "01HXYZ" },
        { "name": "cf-ray", "value": "8a1b2c3d" },
        { "name": "date", "value": "Mon, 01 Jan 2026 00:00:00 GMT" },
        { "name": "server", "value": "cloudflare" },
        { "name": "connection", "value": "keep-alive" },
        { "name": "keep-alive", "value": "timeout=5" }
        """
        let candidates = try await HARParser.parse(data: Self.har(entries: Self.entry(headers: headers)), existingEndpoints: [])
        let headersOut = try #require(candidates.first?.responseHeaders)

        // Nothing describing the transfer survives — the mock re-frames the body itself.
        for dropped in ["content-encoding", "content-length", "connection", "keep-alive", "date", "server"] {
            #expect(
                headersOut.keys.allSatisfy { $0.caseInsensitiveCompare(dropped) != .orderedSame },
                "\(dropped) must not be replayed"
            )
        }
        // Everything describing the response does.
        #expect(headersOut["cache-control"] == "public, max-age=60")
        #expect(headersOut["etag"] == "W/\"abc123\"")
        #expect(headersOut["x-request-id"] == "01HXYZ")
        #expect(headersOut["strict-transport-security"] != nil)
    }

    @Test("HTTP/2 captures carry pseudo-headers, which are framing and not sendable")
    func http2PseudoHeaders() async throws {
        // Chrome and Safari both record `:status` for HTTP/2 responses. Replaying it is illegal.
        let headers = """
        { "name": ":status", "value": "200" },
        { "name": "content-type", "value": "application/json" }
        """
        let candidates = try await HARParser.parse(data: Self.har(entries: Self.entry(headers: headers)), existingEndpoints: [])
        let headersOut = try #require(candidates.first?.responseHeaders)
        #expect(headersOut[":status"] == nil)
        #expect(headersOut.count == 1)
    }

    @Test("A duplicated header keeps the last value, as a client would have seen")
    func duplicateHeaders() async throws {
        let headers = """
        { "name": "x-trace", "value": "first" },
        { "name": "x-trace", "value": "second" },
        { "name": "content-type", "value": "application/json" }
        """
        let candidates = try await HARParser.parse(data: Self.har(entries: Self.entry(headers: headers)), existingEndpoints: [])
        #expect(candidates.first?.responseHeaders["x-trace"] == "second")
    }

    @Test("Header names differing only in case are still recognized as transport headers")
    func headerCasingVaries() async throws {
        // HTTP/2 lowercases; HTTP/1.1 tools do not. A capture may contain either.
        let headers = """
        { "name": "Content-Encoding", "value": "gzip" },
        { "name": "CONTENT-LENGTH", "value": "10" },
        { "name": "Content-Type", "value": "application/json" }
        """
        let candidates = try await HARParser.parse(data: Self.har(entries: Self.entry(headers: headers)), existingEndpoints: [])
        #expect(candidates.first?.responseHeaders.count == 1)
        #expect(candidates.first?.responseHeaders["Content-Type"] == "application/json")
    }

    @Test("A charset on the content type does not stop JSON being detected")
    func contentTypeWithCharset() async throws {
        let candidates = try await HARParser.parse(
            data: Self.har(entries: Self.entry(
                headers: #"{ "name": "content-type", "value": "application/json; charset=utf-8" }"#,
                mimeType: "application/json; charset=utf-8"
            )),
            existingEndpoints: []
        )
        #expect(candidates.first?.responseContentType == .json)
    }

    // MARK: - Bodies real captures contain

    @Test("A non-ASCII body survives import intact")
    func unicodeBody() async throws {
        // Real APIs return names, currencies and emoji; a naive byte count or encoding assumption
        // corrupts them.
        let text = #"{\"name\":\"Ünïcodé ✅ 日本語\",\"price\":\"€10\"}"#
        let candidates = try await HARParser.parse(
            data: Self.har(entries: Self.entry(
                headers: #"{ "name": "content-type", "value": "application/json" }"#,
                text: text
            )),
            existingEndpoints: []
        )
        let body = try #require(candidates.first?.responseBody)
        #expect(body.contains("Ünïcodé"))
        #expect(body.contains("日本語"))
        #expect(body.contains("€10"))
    }

    @Test("An empty body is imported as empty rather than as missing")
    func emptyBody() async throws {
        let candidates = try await HARParser.parse(
            data: Self.har(entries: Self.entry(
                status: 204,
                headers: #"{ "name": "content-type", "value": "application/json" }"#,
                text: ""
            )),
            existingEndpoints: []
        )
        #expect(candidates.first?.statusCode == 204)
        #expect(candidates.first?.bodySizeBytes == 0)
    }

    @Test("A base64 capture is not imported as literal base64 text")
    func base64EncodedBody() async throws {
        // Browsers base64 binary and sometimes text bodies. Importing the encoded form as the mock's
        // body would serve gibberish that looks superficially fine in a listing.
        let encoded = Data(#"{"ok":true}"#.utf8).base64EncodedString()
        let candidates = try await HARParser.parse(
            data: Self.har(entries: Self.entry(
                headers: #"{ "name": "content-type", "value": "application/json" }"#,
                text: encoded,
                extraContent: #", "encoding": "base64""#
            )),
            existingEndpoints: []
        )
        let body = try #require(candidates.first?.responseBody)
        #expect(body == #"{"ok":true}"#, "a base64 capture must be decoded, not stored verbatim")
    }

    @Test("A body past the size limit is dropped rather than silently truncated")
    func oversizedBody() async throws {
        let huge = String(repeating: "x", count: ImportCandidateBuilder.bodySizeLimit + 1_000)
        let candidates = try await HARParser.parse(
            data: Self.har(entries: Self.entry(
                headers: #"{ "name": "content-type", "value": "text/plain" }"#,
                text: huge
            )),
            existingEndpoints: []
        )
        let candidate = try #require(candidates.first)
        #expect(candidate.bodySizeExceedsLimit)
        #expect(candidate.responseBody == nil, "a half-body would be worse than none")
    }

    // MARK: - Statuses real captures contain

    @Test("A request the browser never completed carries status 0, which no mock can serve")
    func cancelledRequestHasUnservableStatus() async throws {
        // Chrome, Safari and Firefox all write `"status": 0` for a request that was cancelled,
        // blocked by an extension or content blocker, or failed in transport — and a capture of a
        // real session normally holds several of them. Every fixture in this suite until now carried
        // a status the app could have served, so nothing here could see what happens when one does
        // not.
        //
        // The parser reports what it read, and the candidate arrives pre-selected. What keeps that 0
        // out of the store is `AppState.commitImportedCandidates`, which now runs the same
        // `EndpointValidator` an edit runs. Before it did, the 0 was stored verbatim and
        // `clampedStatusCode` served 200 for it — the editor showing a status the wire never used.
        let entries = """
        \(Self.entry(url: "https://api.test/v1/cancelled", status: 0, headers: "", text: "")),
        \(Self.entry(headers: #"{ "name": "content-type", "value": "application/json" }"#))
        """
        let candidates = try await HARParser.parse(data: Self.har(entries: entries), existingEndpoints: [])
        let cancelled = try #require(candidates.first(where: { $0.path == "/v1/cancelled" }))

        #expect(cancelled.statusCode == 0)
        #expect(cancelled.isSelected, "nothing but the commit path stands between this and the store")
        #expect(
            EndpointValidator.serveableStatusCodes.contains(cancelled.statusCode) == false,
            "0 is not a status a response can be completed with, so the commit path must refuse it"
        )

        // And the entry beside it is untouched: one dead request must not cost the twenty around it.
        #expect(candidates.count == 2)
        #expect(candidates.contains(where: { $0.path == "/v1/things" && $0.statusCode == 200 }))
    }

    // MARK: - URLs real captures contain

    @Test("Query strings and fragments do not become part of the route")
    func urlsAreNormalized() async throws {
        let candidates = try await HARParser.parse(
            data: Self.har(entries: Self.entry(
                url: "https://api.test/v1/search?q=hello%20world&page=2#results",
                headers: #"{ "name": "content-type", "value": "application/json" }"#
            )),
            existingEndpoints: []
        )
        #expect(candidates.first?.path == "/v1/search")
    }

    @Test("A port and a non-standard scheme do not leak into the path")
    func hostAndPortStripped() async throws {
        let candidates = try await HARParser.parse(
            data: Self.har(entries: Self.entry(
                url: "http://localhost:3000/api/things",
                headers: #"{ "name": "content-type", "value": "application/json" }"#
            )),
            existingEndpoints: []
        )
        #expect(candidates.first?.path == "/api/things")
    }

    // MARK: - Captures that should not crash the importer

    @Test("A capture with no entries imports as nothing rather than failing")
    func emptyCapture() async throws {
        let candidates = try await HARParser.parse(data: Self.har(entries: ""), existingEndpoints: [])
        #expect(candidates.isEmpty)
    }

    @Test("Entries the importer cannot use are skipped, not fatal")
    func partiallyUnusableCapture() async throws {
        // A real capture is full of things that are not mockable API calls: preflights, data URLs,
        // methods Mimic does not model. One bad entry must not lose the other twenty.
        let entries = """
        { "request": { "method": "CONNECT", "url": "https://api.test/tunnel" },
          "response": { "status": 200, "headers": [], "content": { "mimeType": "text/plain", "text": "" } } },
        \(Self.entry(headers: #"{ "name": "content-type", "value": "application/json" }"#))
        """
        let candidates = try await HARParser.parse(data: Self.har(entries: entries), existingEndpoints: [])
        #expect(candidates.count == 1, "the usable entry must still import")
        #expect(candidates.first?.path == "/v1/things")
    }

    @Test("Malformed JSON is reported rather than crashing the importer")
    func malformedCapture() async {
        await #expect(throws: (any Error).self) {
            _ = try await HARParser.parse(data: Data("{ not json".utf8), existingEndpoints: [])
        }
    }
}
