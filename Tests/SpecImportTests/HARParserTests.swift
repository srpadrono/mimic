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

    @Test("Falls back to raw strings for invalid URL paths")
    func extractsInvalidURLPaths() {
        #expect(HARParser.extractPath(from: "api.example.com/users") == "api.example.com/users")
        #expect(HARParser.extractPath(from: "/already/path") == "/already/path")
    }

    @Test("Decodes base64 response content and redacts secrets")
    func decodesBase64AndRedactsSecrets() async throws {
        let payload = #"{"authorization":"Bearer secret-token","api_key":"12345"}"#
        let encoded = Data(payload.utf8).base64EncodedString()
        let harJSON = """
        {
            "log": {
                "entries": [
                    {
                        "request": { "method": "GET", "url": "https://example.com/api/secure" },
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
        let body = try #require(candidates.first?.responseBody)

        #expect(body.contains(#""authorization":"[REDACTED]""#))
        #expect(body.contains(#""api_key":"[REDACTED]""#))
    }
}
