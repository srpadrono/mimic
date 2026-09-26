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

    @Test("A duplicated header keeps the last value under the import policy")
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

    @Test("Transcoded HAR text declares UTF-8 while retaining other media-type parameters")
    func transcodedTextUsesUTF8Charset() async throws {
        let candidates = try await HARParser.parse(data: Self.har(entries: Self.entry(
            headers: #"{ "name": "Content-Type", "value": "text/plain; profile=\"keep; charset=windows-1252\"; charset=\"ISO-8859-1\"; format=flowed" }"#,
            mimeType: "text/plain; charset=ISO-8859-1", text: "café"
        )))
        let candidate = try #require(candidates.first)
        #expect(candidate.responseBody == "café")
        #expect(candidate.bodySizeBytes == 5)
        #expect(candidate.responseHeaders["Content-Type"]
            == #"text/plain; profile="keep; charset=windows-1252"; charset=utf-8; format=flowed"#)
    }

    @Test("Content metadata retains HTML when an exporter omits response headers")
    func contentMetadataSuppliesMediaType() async throws {
        let candidates = try await HARParser.parse(data: Self.har(entries: Self.entry(
            headers: "", mimeType: "text/html; charset=windows-1252", text: "<p>Café</p>"
        )))
        let candidate = try #require(candidates.first)
        #expect(candidate.responseBody == "<p>Café</p>")
        #expect(candidate.responseHeaders["Content-Type"] == "text/html; charset=utf-8")
        #expect(candidate.responseContentType == .plainText)
    }

    @Test("HTML and XML without a charset override stale in-document declarations with UTF-8")
    func markupWithoutCharsetUsesUTF8() async throws {
        let capture = #"""
        {"log":{"entries":[
          {"request":{"method":"GET","url":"https://api.test/page"},"response":{
            "status":200,"headers":[{"name":"Content-Type","value":"text/html"}],
            "content":{"mimeType":"text/html","text":"<meta charset=\"windows-1252\"><p>café</p>"}}},
          {"request":{"method":"GET","url":"https://api.test/text-xml"},"response":{
            "status":200,"headers":[{"name":"Content-Type","value":"text/xml"}],
            "content":{"mimeType":"text/xml","text":"<?xml version=\"1.0\" encoding=\"windows-1252\"?><value>café</value>"}}},
          {"request":{"method":"GET","url":"https://api.test/xml"},"response":{
            "status":200,"headers":[{"name":"Content-Type","value":"application/xml"}],
            "content":{"mimeType":"application/xml","text":"<?xml version=\"1.0\" encoding=\"windows-1252\"?><value>café</value>"}}},
          {"request":{"method":"GET","url":"https://api.test/xhtml"},"response":{
            "status":200,"headers":[{"name":"Content-Type","value":"application/xhtml+xml"}],
            "content":{"mimeType":"application/xhtml+xml","text":"<?xml version=\"1.0\" encoding=\"windows-1252\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><body>café</body></html>"}}}
        ]}}
        """#
        let candidates = try await HARParser.parse(data: Data(capture.utf8))
        #expect(candidates.map { $0.responseHeaders["Content-Type"] } == [
            "text/html; charset=utf-8", "text/xml; charset=utf-8", "application/xml; charset=utf-8",
            "application/xhtml+xml; charset=utf-8",
        ])
        #expect(candidates.map(\.responseBody) == [
            #"<meta charset="windows-1252"><p>café</p>"#,
            #"<?xml version="1.0" encoding="windows-1252"?><value>café</value>"#,
            #"<?xml version="1.0" encoding="windows-1252"?><value>café</value>"#,
            #"<?xml version="1.0" encoding="windows-1252"?><html xmlns="http://www.w3.org/1999/xhtml"><body>café</body></html>"#,
        ])
    }

    @Test("JSON headers without a charset retain their captured spelling")
    func jsonWithoutCharsetIsUnchanged() async throws {
        let capture = #"{"log":{"entries":[{"request":{"method":"GET","url":"https://api.test/problem"},"response":{"status":400,"headers":[{"name":"content-type","value":"Application/Problem+JSON"}],"content":{"text":"{\"detail\":\"café\"}"}}}]}}"#
        let candidates = try await HARParser.parse(data: Data(capture.utf8))
        let candidate = try #require(candidates.first)
        #expect(candidate.responseHeaders["content-type"] == "Application/Problem+JSON")
        #expect(candidate.responseBody == #"{"detail":"café"}"#)
    }

    @Test("A captured Content-Type identifies JSON when content metadata is absent")
    func responseHeaderSuppliesContentType() async throws {
        let capture = #"{"log":{"entries":[{"request":{"method":"GET","url":"https://api.test/report"},"response":{"status":200,"headers":[{"name":"content-type","value":"application/problem+json"}],"content":{"text":"{\"detail\":\"missing\"}"}}}]}}"#
        let candidates = try await HARParser.parse(data: Data(capture.utf8))
        let candidate = try #require(candidates.first)
        #expect(candidate.responseContentType == .json)
        #expect(candidate.responseBody == #"{"detail":"missing"}"#)
    }

    @Test("All Connection fields nominate headers before duplicate merging")
    func connectionNominationsAcrossDuplicateHeaders() async throws {
        let candidates = try await HARParser.parse(data: Self.har(entries: Self.entry(headers: #"{"name":"Connection","value":"X-Hop"},{"name":"connection","value":"X-Other"},{"name":"X-Hop","value":"do not replay"},{"name":"X-Other","value":"also private"},{"name":"X-Trace","value":"keep"}"#)))
        let headers = try #require(candidates.first?.responseHeaders)
        #expect(headers["X-Hop"] == nil)
        #expect(headers["X-Other"] == nil)
        #expect(headers["X-Trace"] == "keep")
        #expect(headers.keys.allSatisfy { $0.lowercased() != "connection" })
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
        #expect(body == #"{"name":"Ünïcodé ✅ 日本語","price":"€10"}"#)
    }

    @Test("A no-content response has no payload and a zero byte count")
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
        #expect(candidates.first?.responseBody == nil)
        #expect(candidates.first?.bodyIsBinary == false)
    }

    @Test("A base64 text capture is decoded rather than imported as literal base64")
    func base64EncodedBody() async throws {
        // Browsers base64 binary and sometimes text bodies. Importing the encoded form as the mock's
        // body would serve gibberish that looks superficially fine in a listing.
        //
        // This case covers the *text* half only — its fixture encodes UTF-8 JSON, so decoding can
        // succeed. Its title used to claim the whole property ("a base64 capture is not imported as
        // literal base64 text") while the binary half was both untested and false: a body whose
        // decoded bytes are not UTF-8 fell through to exactly that literal import. The cases below
        // hold the rest — two genuinely binary bodies, the newline-wrapped form real exporters
        // write, and a declared-base64 body that will not decode at all.
        let encoded = "eyJvayI6dHJ1ZX0="
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

    @Test("A binary body — most of any real capture — imports without a body, flagged")
    func binaryBase64Body() async throws {
        // A PNG header and the gzip magic: the first bytes of two things every browsing session
        // captures. Neither is valid UTF-8 — 0x89 and 0x8B can only continue a sequence, never
        // start one — and that is the property every earlier base64 fixture lacked: each encoded
        // UTF-8 JSON, so the decode-to-text step always succeeded and the fall-through that
        // imported the literal base64 spelling as the body was unreachable from tests while being
        // routine in use. Both fixtures below contain bytes a String cannot reproduce.
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let gzipMagic = Data([0x1F, 0x8B, 0x08, 0x00])
        #expect(String(data: pngHeader, encoding: .utf8) == nil, "the PNG fixture must not be decodable text")
        #expect(String(data: gzipMagic, encoding: .utf8) == nil, "the gzip fixture must not be decodable text")

        let pngEntry = Self.entry(
            url: "https://api.test/assets/logo.png",
            headers: #"{ "name": "content-type", "value": "image/png" }"#,
            mimeType: "image/png",
            text: "iVBORw0KGgo=",
            extraContent: #", "encoding": "base64""#
        )
        let gzipEntry = Self.entry(
            url: "https://api.test/v1/report.gz",
            headers: #"{ "name": "content-type", "value": "application/gzip" }"#,
            mimeType: "application/gzip",
            text: "H4sIAA==",
            extraContent: #", "encoding": "base64""#
        )
        let candidates = try await HARParser.parse(
            data: Self.har(entries: "\(pngEntry), \(gzipEntry)"),
            existingEndpoints: []
        )
        #expect(candidates.count == 2)
        let png = try #require(candidates.first { $0.path == "/assets/logo.png" })
        let gzip = try #require(candidates.first { $0.path == "/v1/report.gz" })

        for candidate in [png, gzip] {
            #expect(
                candidate.responseBody == nil,
                "\(candidate.path): a String body cannot reproduce these bytes — the base64 spelling must not stand in for them"
            )
            #expect(candidate.bodyIsBinary, "\(candidate.path): the review sheet must be told why there is no body")
            #expect(!candidate.isSelected, "\(candidate.path): unavailable bytes must not be imported by default")
            #expect(candidate.bodySizeExceedsLimit == false)
        }
        // The size shown in review is the capture's, not zero — mirroring the oversized path,
        // where the body is gone but the row still says what was there.
        #expect(png.bodySizeBytes == pngHeader.count)
        #expect(gzip.bodySizeBytes == gzipMagic.count)
    }

    @Test("Newline-wrapped base64 — the MIME column width real exporters write — still decodes")
    func newlineWrappedBase64Body() async throws {
        // `Data(base64Encoded:)` is strict by default: the first line break fails the whole
        // decode, and the failure used to take the same silent fall-through as a binary body — the
        // wrapped spelling itself imported as the mock's body, even though the body was text.
        let payload = #"{"rows":[{"id":1,"name":"alpha"},{"id":2,"name":"beta"},{"id":3,"name":"gamma"}],"total":3}"#
        let wrapped = Data(payload.utf8).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        #expect(wrapped.contains("\n"), "a fixture short enough not to wrap cannot fail")

        let candidates = try await HARParser.parse(
            data: Self.har(entries: Self.entry(
                headers: #"{ "name": "content-type", "value": "application/json" }"#,
                // The JSON escape, so the decoded `HARContent.text` carries real newlines.
                text: wrapped.replacingOccurrences(of: "\n", with: "\\n"),
                extraContent: #", "encoding": "base64""#
            )),
            existingEndpoints: []
        )
        let candidate = try #require(candidates.first)
        #expect(candidate.responseBody == payload)
        #expect(candidate.bodyIsBinary == false)
    }

    @Test("A body declared base64 that will not decode is dropped, not imported as its spelling")
    func undecodableBase64Body() async throws {
        // Nine base64 digits is 4n+1, which no amount of ignored characters makes decodable. A
        // body the capture declares to be an *encoding* of the payload must never import as if it
        // were the payload itself.
        let notBase64 = "!!!not-base64!!!"
        #expect(
            Data(base64Encoded: notBase64, options: .ignoreUnknownCharacters) == nil,
            "the fixture must be undecodable, or this test tests the text path"
        )
        let candidates = try await HARParser.parse(
            data: Self.har(entries: Self.entry(
                headers: #"{ "name": "content-type", "value": "application/json" }"#,
                text: notBase64,
                extraContent: #", "encoding": "base64""#
            )),
            existingEndpoints: []
        )
        let candidate = try #require(candidates.first)
        #expect(candidate.responseBody == nil)
        #expect(candidate.bodyIsBinary)
    }

    @Test("Base64 punctuation is rejected instead of silently repaired", arguments: ["e3!0=", "e30=💡"])
    func corruptBase64IsNotRepaired(encoded: String) async throws {
        let candidates = try await HARParser.parse(data: Self.har(entries: Self.entry(
            headers: #"{ "name": "content-type", "value": "application/json" }"#,
            text: encoded,
            extraContent: #", "encoding": "base64""#
        )))
        let candidate = try #require(candidates.first)
        #expect(candidate.responseBody == nil)
        #expect(candidate.bodyIsBinary)
        #expect(candidate.bodySizeBytes == encoded.utf8.count)
    }

    @Test("ASCII whitespace around base64 is accepted without changing the decoded text")
    func base64Whitespace() async throws {
        let candidates = try await HARParser.parse(data: Self.har(entries: Self.entry(
            headers: #"{ "name": "content-type", "value": "application/json" }"#,
            text: #" e3\r\n\t0= "#,
            extraContent: #", "encoding": "base64""#
        )))
        let candidate = try #require(candidates.first)
        #expect(candidate.responseBody == "{}")
        #expect(candidate.bodySizeBytes == 2)
        #expect(!candidate.bodyIsBinary)
    }

    @Test("An unsupported HAR content encoding is flagged instead of replayed as text")
    func unsupportedContentEncoding() async throws {
        let candidates = try await HARParser.parse(data: Self.har(entries: Self.entry(
            headers: #"{ "name": "content-type", "value": "text/plain" }"#,
            mimeType: "text/plain", text: "aGVsbG8",
            extraContent: #", "encoding": "base64url""#
        )))
        let candidate = try #require(candidates.first)
        #expect(candidate.responseBody == nil)
        #expect(candidate.bodyIsBinary)
        #expect(candidate.bodySizeBytes == 7)
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
        #expect(!candidate.isSelected)
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
        // The parser reports what it read but does not select an unservable status by default.
        // Import commit also validates it, so manually selecting the row cannot store a fake reply.
        let entries = """
        \(Self.entry(url: "https://api.test/v1/cancelled", status: 0, headers: "", text: "")),
        \(Self.entry(headers: #"{ "name": "content-type", "value": "application/json" }"#))
        """
        let candidates = try await HARParser.parse(data: Self.har(entries: entries), existingEndpoints: [])
        let cancelled = try #require(candidates.first(where: { $0.path == "/v1/cancelled" }))

        #expect(cancelled.statusCode == 0)
        #expect(!cancelled.isSelected)
        #expect(
            EndpointValidator.serveableStatusCodes.contains(cancelled.statusCode) == false,
            "0 is not a status a response can be completed with, so the commit path must refuse it"
        )

        // And the entry beside it is untouched: one dead request must not cost the twenty around it.
        //
        // Found and asserted in two steps rather than as one `contains(where:)` over `path == …
        // && statusCode == 200`. That spelling made the type checker give up — "unable to type-check
        // this expression in reasonable time", inside the `#expect` expansion, failing the whole
        // SpecImportTests batch on macOS while Linux compiled it. `&&` across a `String` comparison
        // and an integer literal is enough to do it once a macro re-types the expression. This form
        // also says which half is wrong when it fails.
        #expect(candidates.count == 2)
        let things = candidates.first { $0.path == "/v1/things" }
        #expect(things != nil)
        #expect(things?.statusCode == 200)
    }

    @Test("An unusable first capture does not hide a later complete response on the same route")
    func usableLaterCaptureKeepsItsRoute() async throws {
        let capture = #"{"log":{"entries":[{"request":{"method":"GET","url":"https://api.test/report"},"response":{"status":0}},{"request":{"method":"GET","url":"https://api.test/report"},"response":{"status":200,"content":{"size":128,"mimeType":"application/json"}}},{"request":{"method":"GET","url":"https://api.test/report"},"response":{"status":200,"content":{"mimeType":"application/json","text":"{}"}}}]}}"#
        let candidates = try await HARParser.parse(data: Data(capture.utf8))
        try #require(candidates.count == 3)
        #expect(!candidates[0].isSelected)
        #expect(!candidates[1].isSelected)
        #expect(candidates[1].bodyIsUnavailable)
        #expect(!candidates[1].bodyIsBinary)
        #expect(candidates[1].bodySizeBytes == 128)
        #expect(candidates[1].responseBody == nil)
        #expect(candidates[2].isSelected)
        #expect(!candidates[2].isDuplicate)
        #expect(candidates[2].responseBody == "{}")
    }

    @Test("A partial capture does not claim the route before a complete response")
    func completeResponseAfterPartialCapture() async throws {
        let capture = #"{"log":{"entries":[{"request":{"method":"GET","url":"https://api.test/report"},"response":{"status":206,"headers":[{"name":"Content-Range","value":"bytes 0-1/4"}],"content":{"size":2,"mimeType":"text/plain","text":"ab"}}},{"request":{"method":"GET","url":"https://api.test/report"},"response":{"status":200,"content":{"size":4,"mimeType":"text/plain","text":"abcd"}}}]}}"#
        let candidates = try await HARParser.parse(data: Data(capture.utf8))
        try #require(candidates.count == 2)
        #expect(candidates[0].statusCode == 206)
        #expect(!candidates[0].isSelected)
        #expect(!candidates[0].bodyIsUnavailable)
        #expect(!candidates[0].bodyIsBinary)
        #expect(candidates[0].responseBody == "ab")
        #expect(candidates[1].isSelected)
        #expect(!candidates[1].isDuplicate)
        #expect(candidates[1].responseBody == "abcd")
    }

    @Test("Missing content is distinguished from an explicitly empty captured body")
    func missingAndEmptyBodies() async throws {
        let capture = #"{"log":{"entries":[{"request":{"method":"GET","url":"https://api.test/missing"},"response":{"status":200,"bodySize":42}},{"request":{"method":"GET","url":"https://api.test/empty"},"response":{"status":200,"bodySize":42,"content":{"size":42,"text":""}}}]}}"#
        let candidates = try await HARParser.parse(data: Data(capture.utf8))
        try #require(candidates.count == 2)
        #expect(candidates[0].bodyIsUnavailable)
        #expect(candidates[0].bodySizeBytes == 42)
        #expect(!candidates[0].isSelected)
        #expect(!candidates[1].bodyIsUnavailable)
        #expect(candidates[1].bodySizeBytes == 0)
        #expect(candidates[1].isSelected)
    }

    @Test("Bodyless HTTP responses do not require captured representation content")
    func bodylessResponsesAreNotMissing() async throws {
        let capture = #"{"log":{"entries":[{"request":{"method":"HEAD","url":"https://api.test/head"},"response":{"status":200,"content":{"size":42}}},{"request":{"method":"GET","url":"https://api.test/no-content"},"response":{"status":204,"content":{"size":42}}},{"request":{"method":"GET","url":"https://api.test/reset"},"response":{"status":205,"content":{"size":42}}},{"request":{"method":"GET","url":"https://api.test/cached"},"response":{"status":304,"content":{"size":42}}}]}}"#
        let candidates = try await HARParser.parse(data: Data(capture.utf8))
        #expect(candidates.count == 4)
        #expect(candidates.allSatisfy { !$0.bodyIsUnavailable })
        #expect(candidates.allSatisfy { $0.bodySizeBytes == 0 })
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

    @Test("A non-standard port does not leak into the path")
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
        \(Self.entry(url: "data:text/plain,hello", headers: "", mimeType: "text/plain", text: "hello")),
        \(Self.entry(url: "blob:https://api.test/00000000-0000-0000-0000-000000000001", headers: "")),
        \(Self.entry(url: "file:///tmp/captured.json", headers: "")),
        \(Self.entry(url: "http:///missing-host", headers: "")),
        \(Self.entry(url: "", headers: "")),
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
