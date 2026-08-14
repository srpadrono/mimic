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

    @Test("Every name Domain calls a credential is dropped on the way into a mock")
    func everyDomainCredentialIsDroppedOnImport() {
        // Driven off `RequestLog.sensitiveHeaderNames` rather than a list written out here, because a
        // literal in this test would be the same defect one layer up: two lists of credential names
        // that agree on the day they are written and then drift. They had already drifted — the
        // import policy carried four of Domain's six, missing `x-api-key` and `x-auth-token`, so a
        // captured API key was redacted out of the request log and replayed into an endpoint the user
        // may commit. This fails if anything ever puts a second list back.
        #expect(
            RequestLog.sensitiveHeaderNames.isEmpty == false,
            "an empty Domain list would make every case below vacuous"
        )

        for lowercased in RequestLog.sensitiveHeaderNames {
            // Domain stores names lowercased; a capture records them the way the wire had them.
            // Derived rather than listed, so this covers whatever the set contains.
            let asCaptured = lowercased.split(separator: "-")
                .map { String($0).capitalized }
                .joined(separator: "-")

            #expect(ImportHeaderPolicy.shouldDrop(asCaptured), "\(asCaptured) is a credential in Domain")

            // Through the chokepoint every importer goes through, not just the predicate.
            // The ledger is per-import and the builder claims a route into it, so it is declared
            // here rather than passed empty: one candidate, one ledger, nothing pre-existing.
            var ledger = ImportRouteLedger(existingEndpoints: [])
            let candidate = ImportCandidateBuilder.makeCandidate(
                method: .post,
                path: "/session",
                statusCode: 200,
                responseHeaders: [asCaptured: "s3cret", "Content-Type": "application/json"],
                responseBody: #"{"ok":true}"#,
                responseContentType: .json,
                ledger: &ledger
            )
            #expect(
                candidate.responseHeaders[asCaptured] == nil,
                "\(asCaptured) would be written into an endpoint a user may commit"
            )
            #expect(candidate.responseHeaders["Content-Type"] == "application/json")
        }
    }

    @Test("An API key echoed by a login response does not reach a committed mock")
    func apiKeyAndAuthTokenAreDropped() {
        // The two names the import policy used to be missing, named rather than looped, so that
        // narrowing *both* lists together — which the sweep above would not catch, since it only
        // checks that import agrees with Domain — still fails here. A login response handing back
        // `X-Auth-Token` is the ordinary case, not a contrived one.
        let kept = ImportHeaderPolicy.replayable([
            "X-API-Key": "live_pk_abc123",
            "X-Auth-Token": "eyJhbGciOiJIUzI1NiJ9",
            "Content-Type": "application/json",
        ])
        #expect(kept["X-API-Key"] == nil)
        #expect(kept["X-Auth-Token"] == nil)
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
        var ledger = ImportRouteLedger(existingEndpoints: [])
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
            ledger: &ledger
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
