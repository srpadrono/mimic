import Foundation
import Testing
@testable import Domain
@testable import SpecImport

/// A capture describes how *those* bytes reached *that* client. Mimic re-sends the body itself, so
/// replaying transport headers describes a transfer that is not happening — and in one case actively
/// breaks every client.
@Suite("Import header policy")
struct ImportHeaderPolicyTests {

    @Test("Content-Encoding is dropped — the bug that breaks imported mocks")
    func contentEncodingIsDropped() {
        // A HAR stores the *decoded* body, so replaying `Content-Encoding: gzip` makes clients try to
        // gunzip plain JSON and fail before any assertion runs.
        for encoding in ["gzip", "br", "deflate", "zstd", "gzip, br"] {
            let kept = ImportHeaderPolicy.replayable([
                "Content-Encoding": encoding,
                "Content-Type": "application/json",
            ])
            #expect(kept["Content-Encoding"] == nil, "\(encoding) should not survive an import")
            #expect(kept["Content-Type"] == "application/json", "the response's own type must survive")
        }
    }

    @Test("Header matching ignores case and stray whitespace, as HTTP does")
    func matchingIsCaseInsensitive() {
        #expect(ImportHeaderPolicy.shouldDrop("content-encoding"))
        #expect(ImportHeaderPolicy.shouldDrop("Content-Encoding"))
        #expect(ImportHeaderPolicy.shouldDrop("CONTENT-ENCODING"))
        #expect(ImportHeaderPolicy.shouldDrop("  Content-Encoding  "))
    }

    @Test("Framing headers that describe the original connection are dropped")
    func transportHeadersAreDropped() {
        for header in [
            "Content-Length", "Content-Range", "Transfer-Encoding", "Connection",
            "Keep-Alive", "Upgrade", "TE", "Trailer", "Proxy-Authenticate",
        ] {
            #expect(ImportHeaderPolicy.shouldDrop(header), "\(header) is hop-by-hop or framing")
        }
    }

    @Test("HTTP/2 pseudo-headers are dropped — they are framing, not headers")
    func pseudoHeadersAreDropped() {
        #expect(ImportHeaderPolicy.shouldDrop(":status"))
        #expect(ImportHeaderPolicy.shouldDrop(":method"))
    }

    @Test("Credentials never travel into a mock that gets committed and shared")
    func credentialsAreDropped() {
        let kept = ImportHeaderPolicy.replayable([
            "Authorization": "Bearer secret-token",
            "Set-Cookie": "session=abc123; HttpOnly",
            "Cookie": "session=abc123",
            "Content-Type": "application/json",
        ])
        #expect(kept.count == 1)
        #expect(kept["Content-Type"] == "application/json")
    }

    @Test("Headers describing the response itself are kept")
    func semanticHeadersSurvive() {
        let kept = ImportHeaderPolicy.replayable([
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
            "ETag": "\"abc\"",
            "X-Request-Id": "r-1",
            "Retry-After": "30",
            "X-RateLimit-Remaining": "0",
            "Location": "/things/1",
            "Vary": "Accept",
        ])
        #expect(kept.count == 8, "nothing semantic should have been dropped")
    }

    @Test("WWW-Authenticate survives — it is a challenge, not a credential")
    func challengeHeaderSurvives() {
        // Mocking a 401 that tells the client how to authenticate is a legitimate thing to want; the
        // session-expiry journey template does exactly this.
        let kept = ImportHeaderPolicy.replayable(["WWW-Authenticate": "Bearer realm=\"api\""])
        #expect(kept["WWW-Authenticate"] == "Bearer realm=\"api\"")
    }

    @Test("Every importer gets the policy, because it is applied where candidates are built")
    func policyAppliesToEveryImporter() {
        let candidate = ImportCandidateBuilder.makeCandidate(
            method: .get,
            path: "/things",
            statusCode: 200,
            responseHeaders: [
                "Content-Encoding": "gzip",
                "Content-Length": "1234",
                "Content-Type": "application/json",
            ],
            responseBody: #"{"ok":true}"#,
            responseContentType: .json,
            existingEndpoints: []
        )
        #expect(candidate.responseHeaders["Content-Encoding"] == nil)
        #expect(candidate.responseHeaders["Content-Length"] == nil)
        #expect(candidate.responseHeaders["Content-Type"] == "application/json")
    }
}

@Suite("HAR import — transport headers")
struct HARImportHeaderTests {

    /// A HAR entry shaped like a real capture: compressed on the wire, decoded in the file.
    static let compressedCapture = """
    {
      "log": {
        "version": "1.2",
        "creator": { "name": "test", "version": "1" },
        "entries": [
          {
            "request": { "method": "GET", "url": "https://api.test/v1/things" },
            "response": {
              "status": 200,
              "headers": [
                { "name": "Content-Encoding", "value": "gzip" },
                { "name": "Content-Length", "value": "512" },
                { "name": "Content-Type", "value": "application/json" },
                { "name": "Cache-Control", "value": "no-store" },
                { "name": "Set-Cookie", "value": "session=abc; HttpOnly" },
                { "name": "Date", "value": "Mon, 01 Jan 2026 00:00:00 GMT" }
              ],
              "content": { "mimeType": "application/json", "text": "{\\"things\\":[]}" }
            }
          }
        ]
      }
    }
    """

    @Test("A gzip-captured entry imports as a mock a client can actually read")
    func gzipCaptureImportsCleanly() async throws {
        let candidates = try await HARParser.parse(
            data: Data(Self.compressedCapture.utf8),
            existingEndpoints: []
        )
        let candidate = try #require(candidates.first)

        // The body in the HAR — and therefore the body Mimic serves — is decoded text.
        #expect(candidate.responseBody == #"{"things":[]}"#)

        // Declaring an encoding Mimic does not apply is what broke clients.
        #expect(candidate.responseHeaders["Content-Encoding"] == nil)
        #expect(candidate.responseHeaders["Content-Length"] == nil)
        #expect(candidate.responseHeaders["Set-Cookie"] == nil)
        #expect(candidate.responseHeaders["Date"] == nil)

        // What the response actually means survives.
        #expect(candidate.responseHeaders["Content-Type"] == "application/json")
        #expect(candidate.responseHeaders["Cache-Control"] == "no-store")
    }
}

@Suite("HAR import — GraphQL")
struct HARGraphQLImportTests {

    /// A capture of three GraphQL calls: all the same method and path, distinguishable only by body.
    static let graphQLCapture = """
    {
      "log": {
        "version": "1.2",
        "creator": { "name": "test", "version": "1" },
        "entries": [
          {
            "request": {
              "method": "POST", "url": "https://api.test/graphql",
              "postData": { "mimeType": "application/json",
                "text": "{\\"operationName\\":\\"GetAccountSummary\\",\\"query\\":\\"query GetAccountSummary { accountSummary { balance } }\\"}" }
            },
            "response": { "status": 200,
              "headers": [{ "name": "Content-Type", "value": "application/json" }],
              "content": { "mimeType": "application/json", "text": "{\\"data\\":{\\"accountSummary\\":{\\"balance\\":10}}}" } }
          },
          {
            "request": {
              "method": "POST", "url": "https://api.test/graphql",
              "postData": { "mimeType": "application/json",
                "text": "{\\"operationName\\":\\"SendPayment\\",\\"query\\":\\"mutation SendPayment { pay { id } }\\"}" }
            },
            "response": { "status": 201,
              "headers": [{ "name": "Content-Type", "value": "application/json" }],
              "content": { "mimeType": "application/json", "text": "{\\"data\\":{\\"pay\\":{\\"id\\":\\"p1\\"}}}" } }
          },
          {
            "request": {
              "method": "POST", "url": "https://api.test/graphql",
              "postData": { "mimeType": "application/json",
                "text": "{\\"query\\":\\"{ inbox { messages } }\\"}" }
            },
            "response": { "status": 200,
              "headers": [{ "name": "Content-Type", "value": "application/json" }],
              "content": { "mimeType": "application/json", "text": "{\\"data\\":{\\"inbox\\":{\\"messages\\":[]}}}" } }
          }
        ]
      }
    }
    """

    @Test("Each GraphQL operation imports as its own addressable mock")
    func splitsPerOperation() async throws {
        let candidates = try await HARParser.parse(
            data: Data(Self.graphQLCapture.utf8),
            existingEndpoints: []
        )

        #expect(candidates.count == 3)
        // Without the operation these would be three identical `POST /graphql` candidates, and only
        // one of them could ever answer.
        #expect(candidates.map(\.graphqlOperation) == ["GetAccountSummary", "SendPayment", "inbox"])
        #expect(candidates.allSatisfy { $0.path == "/graphql" })
        #expect(candidates.allSatisfy { $0.method == .post })
    }

    @Test("Candidates are named after the operation, not the shared route")
    func namesAfterTheOperation() async throws {
        let candidates = try await HARParser.parse(
            data: Data(Self.graphQLCapture.utf8),
            existingEndpoints: []
        )
        #expect(candidates.map(\.suggestedName) == ["GetAccountSummary", "SendPayment", "inbox"])
        #expect(candidates.allSatisfy { $0.suggestedGroupTag == "GraphQL" })
    }

    @Test("Two operations on one route are not mistaken for duplicates of each other")
    func operationsAreNotDuplicates() async throws {
        let existing = Endpoint(
            name: "GetAccountSummary",
            method: .post,
            path: "/graphql",
            graphqlOperation: "GetAccountSummary"
        )
        let candidates = try await HARParser.parse(
            data: Data(Self.graphQLCapture.utf8),
            existingEndpoints: [existing]
        )

        let summary = try #require(candidates.first { $0.graphqlOperation == "GetAccountSummary" })
        let payment = try #require(candidates.first { $0.graphqlOperation == "SendPayment" })
        #expect(summary.isDuplicate, "the operation already mocked is a duplicate")
        #expect(payment.isDuplicate == false, "a different operation on the same route is not")
    }

    @Test("A plain REST capture is unaffected")
    func restCaptureUnaffected() async throws {
        let rest = """
        { "log": { "version": "1.2", "creator": { "name": "t", "version": "1" }, "entries": [
          { "request": { "method": "GET", "url": "https://api.test/inbox" },
            "response": { "status": 200, "headers": [],
              "content": { "mimeType": "application/json", "text": "{}" } } } ] } }
        """
        let candidates = try await HARParser.parse(data: Data(rest.utf8), existingEndpoints: [])
        #expect(candidates.first?.graphqlOperation == nil)
        #expect(candidates.first?.path == "/inbox")
    }
}
