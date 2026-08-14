import Testing
import Foundation
@testable import SpecImport
import Domain

/// Import tested against the thing an import is *for*: answering a request.
///
/// Every test that already covered this module asserted the path **string** an import produces.
/// Not one asked whether that string can match anything, and it could not: `PathPattern` reads a
/// segment as a wildcard only when it starts with `:`, OpenAPI and Swagger write `{id}`, and
/// nothing converted between them — so every parameterised route imported as literal segments and
/// 404'd for the rest of its life. The document's own prefix was lost to the same blind spot:
/// `basePath` was decoded and read by nothing, `servers` was not decoded at all, so a spec
/// declaring `basePath: /v2` produced `/pet/{petId}` for a server that answers `/v2/pet/42` and
/// even the literal routes were wrong.
///
/// Every fixture in the suite that carried a `basePath` carried `"/"` — the one value for which the
/// prefix is a no-op. The skill `mimic-build-and-test` (`references/real-inputs.md`) names that
/// shape exactly: "a fixture whose every instance agrees on
/// something the format does not require. If all of them put a field in the same place, the parser
/// has only ever been asked to read it there."
///
/// So the assertion that closes this is not another string comparison. It is
/// `PathPattern.matches(requestPath:pattern:)` — the function the running server reaches through
/// `RequestMatcher` — against a path an import actually produced, from the canonical Swagger
/// petstore, because that is the shape a real generator emits: `basePath: "/v2"`, `"/pet/{petId}"`.
@Suite("Imported routes match real requests")
struct ImportedRouteMatchingTests {

    // MARK: - The canonical petstore

    /// Trimmed from the Swagger 2.0 petstore every generator's test suite is built on. What matters
    /// here is the shape, and all of it is load-bearing: a `basePath` that is not `/`, a `host` and
    /// `schemes` this parser does not model (so unknown keys are proven harmless), a parameterised
    /// route, and a literal route sharing its prefix — which is what makes the specificity
    /// assertion below mean something.
    static let petstoreSwagger = """
    {
        "swagger": "2.0",
        "info": { "title": "Swagger Petstore", "version": "1.0.6" },
        "host": "petstore.swagger.io",
        "basePath": "/v2",
        "schemes": ["https", "http"],
        "produces": ["application/json"],
        "paths": {
            "/pet/{petId}": {
                "get": {
                    "tags": ["pet"],
                    "summary": "Find pet by ID",
                    "operationId": "getPetById",
                    "parameters": [
                        { "name": "petId", "in": "path", "required": true, "type": "integer", "format": "int64" }
                    ],
                    "responses": {
                        "200": { "description": "successful operation", "schema": { "$ref": "#/definitions/Pet" } },
                        "404": { "description": "Pet not found" }
                    }
                },
                "delete": {
                    "tags": ["pet"],
                    "summary": "Deletes a pet",
                    "operationId": "deletePet",
                    "responses": { "200": { "description": "successful operation" } }
                }
            },
            "/pet/findByStatus": {
                "get": {
                    "tags": ["pet"],
                    "summary": "Finds Pets by status",
                    "operationId": "findPetsByStatus",
                    "responses": {
                        "200": {
                            "description": "successful operation",
                            "schema": { "type": "array", "items": { "$ref": "#/definitions/Pet" } }
                        }
                    }
                }
            },
            "/store/order/{orderId}": {
                "get": {
                    "tags": ["store"],
                    "summary": "Find purchase order by ID",
                    "operationId": "getOrderById",
                    "responses": { "200": { "description": "successful operation" } }
                }
            }
        },
        "definitions": {
            "Pet": {
                "type": "object",
                "properties": {
                    "id": { "type": "integer", "format": "int64" },
                    "name": { "type": "string", "example": "doggie" },
                    "status": { "type": "string", "enum": ["available", "pending", "sold"] }
                }
            }
        }
    }
    """

    // MARK: - The assertion that was missing

    @Test("A petstore route answers the request the petstore actually serves")
    func petstoreRouteMatchesARealRequest() async throws {
        let candidates = try await OpenAPIParser.parse(data: Data(Self.petstoreSwagger.utf8))
        let byID = try #require(candidates.first { $0.suggestedName == "Find pet by ID" })

        #expect(byID.path == "/v2/pet/:petId")
        // The whole defect in one line, and it catches either half of it on its own. Revert the
        // wildcard rewrite and the pattern is `/v2/pet/{petId}`, whose third segment is a literal no
        // request can equal. Revert the prefix and it is `/pet/:petId`, two segments against the
        // request's three, which `PathPattern` rejects on the count before it compares anything.
        #expect(
            PathPattern.matches(requestPath: "/v2/pet/42", pattern: byID.path),
            "an imported route that cannot match a request is an endpoint that 404s forever"
        )
    }

    @Test("The imported endpoints serve a real request, and the literal route still beats the wildcard")
    func importedEndpointsServeRequests() async throws {
        let candidates = try await OpenAPIParser.parse(data: Data(Self.petstoreSwagger.utf8))
        let endpoints = candidates.map(Self.endpoint(from:))

        // End to end through the matcher the Vapor handler calls, not just the path predicate.
        let byID = try #require(Self.matchedEndpoint(RequestMatcher.match(
            request: IncomingRequest(method: .get, path: "/v2/pet/42"),
            against: endpoints
        )))
        #expect(byID.path == "/v2/pet/:petId")
        #expect(byID.method == .get)

        // `/v2/pet/findByStatus` matches both routes; the one with more literal segments has to win,
        // or importing the petstore would make `findByStatus` unreachable. Query string included,
        // because a real client sends one and matching must ignore it.
        let byStatus = try #require(Self.matchedEndpoint(RequestMatcher.match(
            request: IncomingRequest(method: .get, path: "/v2/pet/findByStatus?status=available"),
            against: endpoints
        )))
        #expect(byStatus.path == "/v2/pet/findByStatus")

        // And the method still narrows: `DELETE /v2/pet/42` is a different endpoint from `GET`.
        let deleted = try #require(Self.matchedEndpoint(RequestMatcher.match(
            request: IncomingRequest(method: .delete, path: "/v2/pet/42"),
            against: endpoints
        )))
        #expect(deleted.method == .delete)
        #expect(deleted.path == "/v2/pet/:petId")
    }

    @Test("A route the document does not describe is still unmatched")
    func unrelatedRequestsDoNotMatch() async throws {
        let candidates = try await OpenAPIParser.parse(data: Data(Self.petstoreSwagger.utf8))
        let endpoints = candidates.map(Self.endpoint(from:))

        // The prefix is not decoration: `/pet/42` is what the *un*prefixed import answered, and the
        // real server does not serve it. A wildcard route must not have become a catch-all either.
        let unprefixed = Self.matchedEndpoint(RequestMatcher.match(
            request: IncomingRequest(method: .get, path: "/pet/42"),
            against: endpoints
        ))
        #expect(unprefixed == nil)

        let tooDeep = Self.matchedEndpoint(RequestMatcher.match(
            request: IncomingRequest(method: .get, path: "/v2/pet/42/photos"),
            against: endpoints
        ))
        #expect(tooDeep == nil)
    }

    @Test("Every route the petstore imports passes the check the commit path applies")
    func importedRoutesAreCommittable() async throws {
        // `ImportCommitter.rejection(for:)` runs `EndpointValidator.validatePath` on every selected
        // candidate, so a prefix joined carelessly — `/v2/` + `/pet` — would not merely mis-route,
        // it would have the whole import refused. Thrown here rather than expected, so a failure
        // names the path.
        let candidates = try await OpenAPIParser.parse(data: Data(Self.petstoreSwagger.utf8))
        #expect(candidates.count == 4)
        for candidate in candidates {
            try EndpointValidator.validatePath(candidate.path)
        }
    }

    @Test("A spec re-imported over the endpoints it created is recognised as a duplicate")
    func reimportIsADuplicate() async throws {
        // Duplicate detection compares the *normalised* route, so what the project holds
        // (`/v2/pet/:petId`) and what the document says (`basePath: /v2` + `/pet/{petId}`) are
        // recognised as the same endpoint. Comparing the raw path would offer to import it twice.
        let existing = Endpoint(name: "Find pet by ID", method: .get, path: "/v2/pet/:petId")
        let candidates = try await OpenAPIParser.parse(
            data: Data(Self.petstoreSwagger.utf8),
            existingEndpoints: [existing]
        )
        // Found in two steps rather than as one `first { $0.path == … && $0.method == .get }`, which
        // is the spelling `RealCaptureTests` records as making the type checker give up inside a
        // macro expansion — `&&` across a `String` comparison and a second one is enough to do it.
        let gets = candidates.filter { $0.method == .get }
        let byID = try #require(gets.first { $0.path == "/v2/pet/:petId" })

        #expect(byID.isDuplicate)
        #expect(byID.isSelected == false, "a duplicate arrives unselected")
    }

    // MARK: - The prefix, in every shape a document writes it

    @Test("A Swagger 2 basePath reaches the route, and `/` still means no prefix")
    func swagger2BasePathShapes() async throws {
        let real = try await Self.swagger2ImportedPath(basePathJSON: "\"/v2\"")
        #expect(real == "/v2/pet/:petId")

        // The value every `basePath` fixture in this suite carried, and the reason none of them
        // could see the prefix being dropped: for `/` the correct answer and the broken answer are
        // the same string. It stays covered — it just cannot be the *only* thing covered.
        let root = try await Self.swagger2ImportedPath(basePathJSON: "\"/\"")
        #expect(root == "/pet/:petId")

        let absent = try await Self.swagger2ImportedPath(basePathJSON: nil)
        #expect(absent == "/pet/:petId")

        let empty = try await Self.swagger2ImportedPath(basePathJSON: "\"\"")
        #expect(empty == "/pet/:petId")

        // A trailing slash must not survive into the join: `/v2//pet/:petId` contains `//`, which
        // `EndpointValidator.validatePath` rejects outright.
        let trailing = try await Self.swagger2ImportedPath(basePathJSON: "\"/v2/\"")
        #expect(trailing == "/v2/pet/:petId")

        // Nested, because a `basePath` of `/api/v2` is at least as common as a bare one.
        let nested = try await Self.swagger2ImportedPath(basePathJSON: "\"/api/v2\"")
        #expect(nested == "/api/v2/pet/:petId")
    }

    @Test("An OpenAPI 3 server URL contributes its path and nothing else")
    func openAPI3ServerShapes() async throws {
        // The normal OpenAPI 3 shape: an absolute URL. Only the path is a route prefix — the host
        // names where the real service lives, and Mimic answers on loopback.
        let absolute = try await Self.openAPI3ImportedPath(
            serversJSON: #"[{ "url": "https://petstore.swagger.io/v2" }]"#
        )
        #expect(absolute == "/v2/pet/:petId")

        // A server that stops at its host declares no prefix at all.
        let hostOnly = try await Self.openAPI3ImportedPath(serversJSON: #"[{ "url": "https://api.example.com" }]"#)
        #expect(hostOnly == "/pet/:petId")

        let hostAndSlash = try await Self.openAPI3ImportedPath(serversJSON: #"[{ "url": "https://api.example.com/" }]"#)
        #expect(hostAndSlash == "/pet/:petId")

        // A relative server URL, which the spec allows and which is what a document served beside
        // its own API tends to write.
        let relative = try await Self.openAPI3ImportedPath(serversJSON: #"[{ "url": "/v3" }]"#)
        #expect(relative == "/v3/pet/:petId")

        // A templated server with declared defaults, which OpenAPI 3 allows and RFC 3986 does not:
        // braces are outside every production a URL is built from, so this string is not a URL and
        // `ImportPath` splits its authority off by hand rather than parsing it.
        let templated = try await Self.openAPI3ImportedPath(serversJSON: """
        [{
            "url": "https://{region}.example.com/{tier}",
            "variables": {
                "region": { "default": "eu", "enum": ["eu", "us"] },
                "tier": { "default": "v2" }
            }
        }]
        """)
        #expect(templated == "/v2/pet/:petId")

        let absent = try await Self.openAPI3ImportedPath(serversJSON: nil)
        #expect(absent == "/pet/:petId")

        let emptyList = try await Self.openAPI3ImportedPath(serversJSON: "[]")
        #expect(emptyList == "/pet/:petId")
    }

    // MARK: - What the rewrite does with each shape, including the ones it declines

    @Test("Each shape a spec can write a segment in, and what it becomes")
    func wildcardRewriteRules() {
        #expect(ImportPath.route("/api/users/{id}") == "/api/users/:id")
        #expect(ImportPath.route("/basic-auth/{user}/{passwd}") == "/basic-auth/:user/:passwd")
        #expect(ImportPath.route("/api/users") == "/api/users", "a literal route is untouched")

        // Already Mimic's own syntax: translated once, not twice. `::id` would match nothing.
        #expect(ImportPath.route("/users/:id") == "/users/:id")

        // A nameless parameter is still a parameter. `{}` left literal is a segment no request can
        // equal; the text after the colon is decoration as far as `PathPattern` is concerned.
        let nameless = ImportPath.route("/things/{}")
        #expect(nameless == "/things/:param")
        #expect(PathPattern.matches(requestPath: "/things/anything", pattern: nameless))

        // RFC 6570 modifiers and stray whitespace are dropped from the name, not carried into it.
        #expect(ImportPath.route("/files/{petId*}") == "/files/:petId")
        #expect(ImportPath.route("/files/{ petId }") == "/files/:petId")

        // Shape preserved: the leading slash comes back, and a trailing slash the spec wrote stays.
        #expect(ImportPath.route("/pets/") == "/pets/")
        #expect(ImportPath.route("/") == "/")
    }

    @Test("A parameter covering only part of a segment imports literally, and that is the decision")
    func partialSegmentParametersStayLiteral() {
        // Matching is segment-wise: the only wildcard available covers a whole segment. So there is
        // no rewrite of `/files/{name}.json` that means what the spec means, and the choice is
        // between a route that visibly does not match and one that silently matches too much.
        let partial = ImportPath.route("/files/{name}.json")
        #expect(partial == "/files/{name}.json")
        #expect(
            PathPattern.matches(requestPath: "/files/report.json", pattern: partial) == false,
            "this is the documented cost: the route 404s until someone edits the path"
        )
        // …and this is what was rejected in exchange. `:name` would answer requests the document
        // never described, which is worse than a route that is obviously wrong.
        #expect(PathPattern.matches(requestPath: "/files/report.xml", pattern: "/files/:name"))

        #expect(ImportPath.route("/v{major}/users") == "/v{major}/users")
        #expect(ImportPath.route("/x/{a}-{b}") == "/x/{a}-{b}")
        #expect(ImportPath.route("/x/{unclosed") == "/x/{unclosed")
    }

    // MARK: - What must not have changed

    @Test("A spec with no parameters and no prefix imports exactly as it did before")
    func literalRoutesImportUnchanged() async throws {
        // This is the path that already worked, and callers may depend on it. Both formats.
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Literal", "version": "1.0" },
            "paths": {
                "/api/users": {
                    "get": { "summary": "List users", "responses": { "200": { "description": "OK" } } }
                }
            }
        }
        """
        let openAPI3Candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))
        #expect(openAPI3Candidates.first?.path == "/api/users")

        let swagger2Path = try await Self.swagger2ImportedPath(basePathJSON: nil, path: "/api/users")
        #expect(swagger2Path == "/api/users")
    }

    @Test("A captured path is not a template and is imported as captured")
    func harPathsAreUntouched() async throws {
        let candidates = try await HARParser.parse(data: Self.har(url: "https://api.test/api/v1/users/123"))
        #expect(candidates.first?.path == "/api/v1/users/123")
    }

    // MARK: - The encoding a capture is written in

    @Test("A capture whose path is percent-encoded answers the request that produced it")
    func percentEncodedCaptureAnswersItsOwnRequest() async throws {
        // Every segment here is a literal, and that is the point. The test named
        // `percentEncodedPath` in `Tests/MockServerEngineTests/RealTrafficTests.swift` claims this
        // property and cannot fail on it: its fixture route is `/things/:id`, and `PathPattern`
        // skips a `:` segment before it compares anything, so that request matches whichever
        // encoding either side happens to use.
        //
        // A browser writes the URL encoded, and encoded is the only form the server can hand the
        // matcher: `VaporConfigurator` builds its `IncomingRequest` from `req.url.path`, which Vapor
        // answers with `percentEncodedPath` (4.121.3, `Sources/Vapor/Utilities/URI.swift:179`).
        let candidates = try await HARParser.parse(data: Self.har(url: "https://api.test/v1/caf%C3%A9/my%20items"))
        let candidate = try #require(candidates.first)
        #expect(candidate.path == "/v1/caf%C3%A9/my%20items")

        let endpoints = [Self.endpoint(from: candidate)]
        let matched = try #require(Self.matchedEndpoint(RequestMatcher.match(
            request: IncomingRequest(method: .get, path: "/v1/caf%C3%A9/my%20items"),
            against: endpoints
        )))
        #expect(matched.path == "/v1/caf%C3%A9/my%20items")

        // And the decoded spelling — what the importer used to produce — matches nothing the server
        // can receive. This is the whole defect: the endpoint imports, appears in the sidebar, and
        // 404s forever.
        let decoded = Self.matchedEndpoint(RequestMatcher.match(
            request: IncomingRequest(method: .get, path: "/v1/café/my items"),
            against: endpoints
        ))
        #expect(decoded == nil)
    }

    // MARK: - A capture repeats itself

    @Test("A capture that hits one route twice imports it once, and flags the repeat")
    func repeatedRouteIsFlaggedWithinTheBatch() async throws {
        let candidates = try await HARParser.parse(data: Data(Self.repeatedCartCapture.utf8))

        // Every entry is still listed — flagged, not dropped, exactly as a duplicate of a
        // pre-existing endpoint is. The review sheet reports what was captured.
        #expect(candidates.count == 3)
        #expect(candidates.map(\.path) == ["/v1/cart", "/v1/cart/items", "/v1/cart"])
        #expect(candidates.map(\.isDuplicate) == [false, false, true])
        #expect(candidates.map(\.isSelected) == [true, true, false])

        // What the sheet's defaults commit: one endpoint per route, and the response that answers is
        // the one whose row was checked. `ImportCommitter` issues one `.endpointCreate` per selected
        // candidate, so before this the same two routes produced three endpoints.
        let selected = candidates.filter(\.isSelected).map(Self.endpoint(from:))
        #expect(selected.count == 2)
        let served = RequestMatcher.resolve(
            request: IncomingRequest(method: .get, path: "/v1/cart"),
            against: selected,
            globalDelayMs: 0
        )
        #expect(served.body == #"{"items":[]}"#)
    }

    @Test("Selecting the repeats anyway does not change which one answers")
    func committingEveryRepeatStillServesTheFirst() async throws {
        // This is why the *first* claim is the one left selected rather than the last.
        // `RequestMatcher.match` replaces its best only on strictly-greater specificity, so among
        // endpoints of equal specificity the first declared answers. A user who overrides the
        // defaults and imports all three therefore gets the same response the defaults would have
        // given — and the two later rows are dead weight, which is what deselecting them says.
        let candidates = try await HARParser.parse(data: Data(Self.repeatedCartCapture.utf8))
        let all = candidates.map(Self.endpoint(from:))
        #expect(all.count == 3)

        let served = RequestMatcher.resolve(
            request: IncomingRequest(method: .get, path: "/v1/cart"),
            against: all,
            globalDelayMs: 0
        )
        #expect(served.body == #"{"items":[]}"#, "the later repeats are unreachable, whoever selected them")
    }

    @Test("A wildcard segment does not end up naming or grouping the endpoint")
    func wildcardSegmentsDoNotNameTheEndpoint() async throws {
        // No `summary` and no `operationId`, so the shared fallback in `ImportCandidateBuilder` is
        // what names this — and a segment that stands for "any id" names the resource no better
        // than the `123` the fallback already skips.
        let spec = """
        {
            "swagger": "2.0",
            "info": { "title": "Petstore", "version": "1.0" },
            "basePath": "/v2",
            "produces": ["application/json"],
            "paths": {
                "/pet/{petId}": { "get": { "responses": { "200": { "description": "OK" } } } }
            }
        }
        """
        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))
        let candidate = try #require(candidates.first)

        #expect(candidate.path == "/v2/pet/:petId")
        #expect(candidate.suggestedName == "Get Pet")
        // Named and grouped from the route the *document* wrote, without the prefix: a spec served
        // under `/mock` must not tag every endpoint in it "Mock".
        #expect(candidate.suggestedGroupTag == "Pet")
    }

    // MARK: - Fixtures

    /// A one-route Swagger 2 document whose `basePath` is written exactly as `basePathJSON`, or
    /// omitted entirely when that is `nil` — the case a fixture cannot express by passing a value.
    static func swagger2(basePathJSON: String?, path: String) -> Data {
        let line = basePathJSON.map { "\"basePath\": \($0)," } ?? ""
        return Data("""
        {
            "swagger": "2.0",
            "info": { "title": "Prefix", "version": "1.0" },
            \(line)
            "produces": ["application/json"],
            "paths": {
                "\(path)": {
                    "get": { "summary": "Find pet by ID", "responses": { "200": { "description": "OK" } } }
                }
            }
        }
        """.utf8)
    }

    /// A one-route OpenAPI 3 document whose `servers` is written exactly as `serversJSON`, or
    /// omitted when that is `nil`.
    ///
    /// The route is fixed at `/pet/{petId}` and its parameter is *declared*, which is what a real
    /// generator emits — and it keeps these cases about `servers` alone, rather than about whether
    /// OpenAPIKit will decode a document whose path names a parameter the operation does not.
    static func openAPI3(serversJSON: String?) -> Data {
        let line = serversJSON.map { "\"servers\": \($0)," } ?? ""
        return Data("""
        {
            "openapi": "3.0.3",
            "info": { "title": "Prefix", "version": "1.0" },
            \(line)
            "paths": {
                "/pet/{petId}": {
                    "get": {
                        "summary": "Find pet by ID",
                        "parameters": [
                            { "name": "petId", "in": "path", "required": true, "schema": { "type": "integer" } }
                        ],
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }
        """.utf8)
    }

    /// Optional rather than `#require`d so a document that imported *nothing* fails the comparison
    /// at the call site, naming the case, instead of aborting the whole test.
    static func swagger2ImportedPath(basePathJSON: String?, path: String = "/pet/{petId}") async throws -> String? {
        try await OpenAPIParser.parse(data: swagger2(basePathJSON: basePathJSON, path: path)).first?.path
    }

    static func openAPI3ImportedPath(serversJSON: String?) async throws -> String? {
        try await OpenAPIParser.parse(data: openAPI3(serversJSON: serversJSON)).first?.path
    }

    /// The cart before an add, the add, and the cart after it: one route captured twice with two
    /// different bodies, with an unrelated entry in between so the ledger has to survive it.
    ///
    /// This is what a capture of real traffic *is* — a browser hits `/v1/cart` every time the page
    /// re-renders. `HARParser.parse` compared each entry against the endpoints the project already
    /// held and accumulated nothing, so all three arrived unflagged and pre-selected, and all three
    /// were committed onto two routes.
    static let repeatedCartCapture = """
    { "log": { "version": "1.2", "creator": { "name": "browser", "version": "1" }, "entries": [
      { "request": { "method": "GET", "url": "https://api.test/v1/cart" },
        "response": { "status": 200, "headers": [],
          "content": { "mimeType": "application/json", "text": "{\\"items\\":[]}" } } },
      { "request": { "method": "POST", "url": "https://api.test/v1/cart/items" },
        "response": { "status": 201, "headers": [],
          "content": { "mimeType": "application/json", "text": "{\\"id\\":\\"sku-1\\"}" } } },
      { "request": { "method": "GET", "url": "https://api.test/v1/cart" },
        "response": { "status": 200, "headers": [],
          "content": { "mimeType": "application/json", "text": "{\\"items\\":[{\\"id\\":\\"sku-1\\"}]}" } } }
    ] } }
    """

    static func har(url: String) -> Data {
        Data("""
        { "log": { "version": "1.2", "creator": { "name": "browser", "version": "1" }, "entries": [
          { "request": { "method": "GET", "url": "\(url)" },
            "response": { "status": 200,
              "headers": [ { "name": "content-type", "value": "application/json" } ],
              "content": { "mimeType": "application/json", "text": "{}" } } } ] } }
        """.utf8)
    }

    /// A candidate as the commit path would store it: one scenario, made active, so the matcher has
    /// something to select. `RequestMatcher` skips an endpoint whose `activeScenarioID` resolves to
    /// nothing, which would make a matching test pass for the wrong reason.
    static func endpoint(from candidate: ImportCandidate) -> Endpoint {
        let scenario = Scenario(
            name: "Imported",
            statusCode: candidate.statusCode,
            headers: candidate.responseHeaders,
            body: candidate.responseBody,
            bodyContentType: candidate.responseContentType
        )
        return Endpoint(
            name: candidate.suggestedName,
            method: candidate.method,
            path: candidate.path,
            scenarios: [scenario],
            activeScenarioID: scenario.id,
            groupTag: candidate.suggestedGroupTag
        )
    }

    static func matchedEndpoint(_ result: MatchResult) -> Endpoint? {
        if case let .matched(endpoint, _) = result { return endpoint }
        return nil
    }
}
