import Testing
import Foundation
@testable import SpecImport
import Domain

@Suite("HARParser")
struct HARParserTests {

    // MARK: - Valid HAR Parsing

    @Test("Parses a valid HAR file with one entry")
    func parseValidHAR() async throws {
        let harJSON = """
        {
            "log": {
                "version": "1.2",
                "creator": { "name": "Test", "version": "1.0" },
                "entries": [
                    {
                        "request": {
                            "method": "GET",
                            "url": "https://api.example.com/api/v1/users"
                        },
                        "response": {
                            "status": 200,
                            "content": {
                                "mimeType": "application/json",
                                "text": "{\\"users\\": []}"
                            }
                        }
                    }
                ]
            }
        }
        """
        let data = Data(harJSON.utf8)
        let candidates = try await HARParser.parse(data: data)

        #expect(candidates.count == 1)
        let c = candidates[0]
        #expect(c.method == .get)
        #expect(c.path == "/api/v1/users")
        #expect(c.statusCode == 200)
        #expect(c.responseBody == "{\"users\": []}")
        #expect(c.responseContentType == .json)
        #expect(c.isSelected == true)
        #expect(c.isDuplicate == false)
    }

    @Test("Parses multiple entries")
    func parseMultipleEntries() async throws {
        let harJSON = """
        {
            "log": {
                "entries": [
                    {
                        "request": { "method": "GET", "url": "https://example.com/api/users" },
                        "response": { "status": 200 }
                    },
                    {
                        "request": { "method": "POST", "url": "https://example.com/api/users" },
                        "response": { "status": 201 }
                    },
                    {
                        "request": { "method": "DELETE", "url": "https://example.com/api/users/1" },
                        "response": { "status": 204 }
                    }
                ]
            }
        }
        """
        let data = Data(harJSON.utf8)
        let candidates = try await HARParser.parse(data: data)

        #expect(candidates.count == 3)
        #expect(candidates[0].method == .get)
        #expect(candidates[1].method == .post)
        #expect(candidates[2].method == .delete)
    }

    // MARK: - Malformed HAR

    @Test("Throws on invalid JSON")
    func throwsOnInvalidJSON() async {
        let data = Data("not json".utf8)
        await #expect(throws: (any Error).self) {
            try await HARParser.parse(data: data)
        }
    }

    @Test("Skips entries with unknown HTTP methods")
    func skipsUnknownMethods() async throws {
        let harJSON = """
        {
            "log": {
                "entries": [
                    {
                        "request": { "method": "PROPFIND", "url": "https://example.com/dav" },
                        "response": { "status": 207 }
                    },
                    {
                        "request": { "method": "GET", "url": "https://example.com/health" },
                        "response": { "status": 200 }
                    }
                ]
            }
        }
        """
        let data = Data(harJSON.utf8)
        let candidates = try await HARParser.parse(data: data)

        #expect(candidates.count == 1)
        #expect(candidates[0].method == .get)
    }

    // MARK: - Body Size Cap

    @Test("Flags entries exceeding body size limit")
    func flagsLargeBody() async throws {
        let largeBody = String(repeating: "x", count: HARParser.bodySizeLimit + 1)
        let harJSON = """
        {
            "log": {
                "entries": [
                    {
                        "request": { "method": "GET", "url": "https://example.com/big" },
                        "response": {
                            "status": 200,
                            "content": { "text": "\(largeBody)" }
                        }
                    }
                ]
            }
        }
        """
        let data = Data(harJSON.utf8)
        let candidates = try await HARParser.parse(data: data)

        #expect(candidates.count == 1)
        #expect(candidates[0].bodySizeExceedsLimit == true)
        #expect(candidates[0].responseBody == nil) // Body stripped when over limit
    }

    // MARK: - Path Extraction

    @Test("Extracts path from full URL")
    func extractsPath() async {
        #expect(HARParser.extractPath(from: "https://api.example.com/api/v1/users?page=1") == "/api/v1/users")
        #expect(HARParser.extractPath(from: "http://localhost:8080/health") == "/health")
        #expect(HARParser.extractPath(from: "https://example.com") == "/")
    }

    // MARK: - Group Tag Suggestion

    @Test("Suggests group tag from meaningful path segment")
    func suggestsGroupTag() async {
        #expect(HARParser.suggestGroupTag(path: "/api/v1/users/123") == "Users")
        #expect(HARParser.suggestGroupTag(path: "/api/v1/posts") == "Posts")
        #expect(HARParser.suggestGroupTag(path: "/") == nil)
    }

    // MARK: - Name Suggestion

    @Test("Generates name from method and path")
    func suggestsName() async {
        #expect(HARParser.suggestName(method: .get, path: "/api/v1/users") == "Get Users")
        #expect(HARParser.suggestName(method: .post, path: "/api/v1/users") == "Create Users")
        #expect(HARParser.suggestName(method: .delete, path: "/api/v1/users/123") == "Delete Users")
        #expect(HARParser.suggestName(method: .head, path: "/api/v1/users") == "Head Users")
        #expect(HARParser.suggestName(method: .options, path: "/api/v1/users") == "Options Users")
    }

    // MARK: - Duplicate Detection

    @Test("Detects duplicates against existing endpoints")
    func detectsDuplicates() async throws {
        let existing = [
            Endpoint(name: "Get Users", method: .get, path: "/api/users")
        ]
        let harJSON = """
        {
            "log": {
                "entries": [
                    {
                        "request": { "method": "GET", "url": "https://example.com/api/users" },
                        "response": { "status": 200 }
                    },
                    {
                        "request": { "method": "POST", "url": "https://example.com/api/users" },
                        "response": { "status": 201 }
                    }
                ]
            }
        }
        """
        let data = Data(harJSON.utf8)
        let candidates = try await HARParser.parse(data: data, existingEndpoints: existing)

        #expect(candidates.count == 2)
        #expect(candidates[0].isDuplicate == true)
        #expect(candidates[0].isSelected == false) // Duplicates deselected by default
        #expect(candidates[1].isDuplicate == false)
        #expect(candidates[1].isSelected == true)
    }

    // MARK: - Response Headers

    @Test("Filters out transport headers from response")
    func filtersTransportHeaders() async throws {
        let harJSON = """
        {
            "log": {
                "entries": [
                    {
                        "request": { "method": "GET", "url": "https://example.com/api/test" },
                        "response": {
                            "status": 200,
                            "headers": [
                                { "name": "Content-Type", "value": "application/json" },
                                { "name": "X-Custom", "value": "hello" },
                                { "name": "content-length", "value": "42" },
                                { "name": "transfer-encoding", "value": "chunked" },
                                { "name": "date", "value": "Mon, 01 Jan 2024" },
                                { "name": "server", "value": "nginx" }
                            ]
                        }
                    }
                ]
            }
        }
        """
        let data = Data(harJSON.utf8)
        let candidates = try await HARParser.parse(data: data)

        let headers = candidates[0].responseHeaders
        #expect(headers["Content-Type"] == "application/json")
        #expect(headers["X-Custom"] == "hello")
        #expect(headers["content-length"] == nil)
        #expect(headers["transfer-encoding"] == nil)
        #expect(headers["date"] == nil)
        #expect(headers["server"] == nil)
    }

    @Test("Formats body size labels across thresholds")
    func bodySizeLabels() {
        let candidate = ImportCandidate(
            id: UUID(),
            isSelected: true,
            method: .get,
            path: "/users",
            suggestedName: "Users",
            suggestedGroupTag: "Users",
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            responseContentType: .json,
            bodySizeBytes: 512,
            bodySizeExceedsLimit: false,
            isDuplicate: false
        )
        #expect(candidate.bodySizeLabel == "512 B")

        let kilobytes = ImportCandidate(
            id: UUID(),
            isSelected: true,
            method: .get,
            path: "/users",
            suggestedName: "Users",
            suggestedGroupTag: "Users",
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            responseContentType: .json,
            bodySizeBytes: 2_048,
            bodySizeExceedsLimit: false,
            isDuplicate: false
        )
        #expect(kilobytes.bodySizeLabel == "2.0 KB")

        let megabytes = ImportCandidate(
            id: UUID(),
            isSelected: true,
            method: .get,
            path: "/users",
            suggestedName: "Users",
            suggestedGroupTag: "Users",
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            responseContentType: .json,
            bodySizeBytes: 1_572_864,
            bodySizeExceedsLimit: true,
            isDuplicate: false
        )
        #expect(megabytes.bodySizeLabel == "1.5 MB")
    }

    /// This used to assert `"api.example.com/users"` came back unchanged, and passed — codifying the
    /// bug rather than the behaviour. A path with no leading slash matches no request the server can
    /// receive, so that endpoint imported, appeared in the list, and answered nothing.
    @Test("Every extracted path is routable, whatever the capture looked like")
    func extractedPathsAreAlwaysRoutable() {
        // A full URL: scheme and host stripped.
        #expect(HARParser.extractPath(from: "https://api.example.com/v1/users") == "/v1/users")
        // Already a path: unchanged.
        #expect(HARParser.extractPath(from: "/already/path") == "/already/path")
        // Schemeless but host-shaped — `URLComponents` parses this as a relative reference and
        // succeeds, which is why the old fallback never ran.
        #expect(HARParser.extractPath(from: "api.example.com/users") == "/users")
        // Genuinely relative, with no host to strip: a leading slash is added and nothing is lost.
        #expect(HARParser.extractPath(from: "users/123") == "/users/123")
        // A URL with no path at all still has to name one.
        #expect(HARParser.extractPath(from: "https://api.example.com") == "/")
        #expect(HARParser.extractPath(from: "") == "/")
        // One dotted segment with nothing behind it is a filename, not a host — re-parsing it as one
        // would leave an empty path and lose the segment. A bare hostname is indistinguishable from a
        // filename here, so it is kept rather than dropped: showing the user `/api.example.com` in the
        // import review is recoverable, silently importing `/` is not.
        #expect(HARParser.extractPath(from: "logo.png") == "/logo.png")
        #expect(HARParser.extractPath(from: "api.example.com") == "/api.example.com")

        for capture in ["https://api.example.com/v1/users", "/already/path", "api.example.com/users",
                        "users/123", "https://api.example.com", "", "?query=only", "#fragment"] {
            #expect(
                HARParser.extractPath(from: capture).hasPrefix("/"),
                "\"\(capture)\" produced an unroutable path"
            )
        }
    }

    @Test("Decodes base64 response content and reproduces the body verbatim")
    func decodesBase64AndKeepsBodyVerbatim() async throws {
        // Every key in this payload was mangled by the redaction pass this replaced. The
        // sensitive-key match was a substring, so `author` matched on "auth", `keywords` and
        // `monkey` on "key", `shipping` and `typing` on "pin" — ordinary fields in ordinary
        // responses. `sessionCount` matched too and came back *quoted*, turning a number into a
        // string under a client that had every right to expect a number.
        let payload = #"{"author":"Jane Roe","keywords":["a","b"],"shipping":"express","sessionCount":42,"typing":true,"monkey":"George"}"#
        let body = try await importedResponseBody(payload: payload, path: "/api/articles")

        #expect(body == payload)
        #expect(body.contains("REDACTED") == false)
    }

    @Test("A captured credential is imported as captured, not rewritten")
    func credentialsAreImportedAsCaptured() async throws {
        // The deliberate trade after redaction was removed: an import reproduces the capture, so a
        // real token lands in the project rather than a placeholder that would make the mock answer
        // something the real server never said. `SECURITY.md` states it, and the import review sheet
        // is where a user is expected to catch it.
        let payload = #"{"access_token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln","token_type":"Bearer"}"#
        let body = try await importedResponseBody(payload: payload, path: "/oauth/token")

        #expect(body == payload)
    }

    /// Round-trips a payload through a minimal single-entry HAR, base64-encoded as browsers export it.
    private func importedResponseBody(payload: String, path: String) async throws -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
        let harJSON = """
        {
            "log": {
                "entries": [
                    {
                        "request": { "method": "GET", "url": "https://example.com\(path)" },
                        "response": {
                            "status": 200,
                            "content": {
                                "mimeType": "application/json",
                                "encoding": "base64",
                                "text": "\(encoded)"
                            }
                        }
                    }
                ]
            }
        }
        """
        let candidates = try await HARParser.parse(data: Data(harJSON.utf8))
        return try #require(candidates.first?.responseBody)
    }
}
