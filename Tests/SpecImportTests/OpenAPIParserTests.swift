import Testing
import Foundation
@testable import SpecImport
import Domain

@Suite("OpenAPIParser")
struct OpenAPIParserTests {

    // MARK: - Valid OpenAPI Parsing

    @Test("Parses a valid OpenAPI v3 spec with one path")
    func parseValidSpec() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test API", "version": "1.0.0" },
            "paths": {
                "/api/users": {
                    "get": {
                        "operationId": "list_users",
                        "responses": {
                            "200": {
                                "description": "Success",
                                "content": {
                                    "application/json": {
                                        "example": [{"id": 1, "name": "Alice"}]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates.count == 1)
        let c = candidates[0]
        #expect(c.method == .get)
        #expect(c.path == "/api/users")
        #expect(c.statusCode == 200)
        #expect(c.suggestedName == "List Users")
        #expect(c.responseBody != nil)
        #expect(c.responseContentType == .json)
        #expect(c.isSelected == true)
    }

    @Test("Parses multiple operations on one path")
    func parseMultipleOperations() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/users": {
                    "get": {
                        "responses": { "200": { "description": "OK" } }
                    },
                    "post": {
                        "responses": { "201": { "description": "Created" } }
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates.count == 2)
        #expect(candidates[0].method == .get)
        #expect(candidates[0].statusCode == 200)
        #expect(candidates[1].method == .post)
        #expect(candidates[1].statusCode == 201)
    }

    @Test("Parses multiple paths")
    func parseMultiplePaths() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/users": {
                    "get": { "responses": { "200": { "description": "OK" } } }
                },
                "/api/posts": {
                    "get": { "responses": { "200": { "description": "OK" } } }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates.count == 2)
        let paths = Set(candidates.map(\.path))
        #expect(paths.contains("/api/users"))
        #expect(paths.contains("/api/posts"))
    }

    // MARK: - Name Generation

    @Test("Uses operationId for name when available")
    func usesOperationId() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/users": {
                    "get": {
                        "operationId": "get_all_users",
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates[0].suggestedName == "Get All Users")
    }

    @Test("Falls back to summary when no operationId")
    func usesSummary() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/users": {
                    "get": {
                        "summary": "Retrieve all users",
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates[0].suggestedName == "Retrieve all users")
    }

    // MARK: - Example Pre-fill

    @Test("Pre-fills response body from example")
    func preFillsExample() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/health": {
                    "get": {
                        "responses": {
                            "200": {
                                "description": "OK",
                                "content": {
                                    "application/json": {
                                        "example": {"status": "healthy"}
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates[0].responseBody != nil)
        #expect(candidates[0].responseBody!.contains("healthy"))
    }

    @Test("Generates fallback body from response description when no example or schema")
    func noExampleFallsBackToPlaceholder() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/ping": {
                    "get": {
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates[0].responseBody != nil)
        #expect(candidates[0].responseBody!.contains("OK"))
    }

    @Test("Generates fallback body with parameters for OpenAPI 3.x")
    func fallbackWithParameters() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/users/{id}": {
                    "get": {
                        "parameters": [
                            {
                                "name": "id",
                                "in": "path",
                                "required": true,
                                "schema": { "type": "integer" }
                            }
                        ],
                        "responses": {
                            "200": { "description": "User details" }
                        }
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        let body = candidates[0].responseBody!
        #expect(body.contains("User details"))
        #expect(body.contains("\"id\""))
    }

    // MARK: - Duplicate Detection

    @Test("Detects duplicates against existing endpoints")
    func detectsDuplicates() async throws {
        let existing = [
            Endpoint(name: "Get Users", method: .get, path: "/api/users")
        ]
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/users": {
                    "get": { "responses": { "200": { "description": "OK" } } },
                    "post": { "responses": { "201": { "description": "Created" } } }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data, existingEndpoints: existing)

        let getCandidates = candidates.filter { $0.method == .get }
        let postCandidates = candidates.filter { $0.method == .post }

        #expect(getCandidates.first?.isDuplicate == true)
        #expect(getCandidates.first?.isSelected == false)
        #expect(postCandidates.first?.isDuplicate == false)
        #expect(postCandidates.first?.isSelected == true)
    }

    // MARK: - Schema Example Generation

    @Test("Generates example from schema when no explicit example")
    func generatesFromSchema() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/users": {
                    "get": {
                        "responses": {
                            "200": {
                                "description": "OK",
                                "content": {
                                    "application/json": {
                                        "schema": {
                                            "type": "object",
                                            "properties": {
                                                "id": { "type": "integer" },
                                                "name": { "type": "string" },
                                                "active": { "type": "boolean" },
                                                "role": { "type": "string", "enum": ["admin", "user"] }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates[0].responseBody != nil, "Should generate body from schema")
        let body = candidates[0].responseBody!
        #expect(body.contains("\"id\""))
        #expect(body.contains("\"name\""))
        #expect(body.contains("\"active\""))
        #expect(body.contains("\"admin\"")) // first enum value
    }

    @Test("Swagger 2.0 generates example from schema definitions")
    func swagger2GeneratesFromSchema() async throws {
        let spec = """
        {
            "swagger": "2.0",
            "info": { "title": "Test", "version": "1.0" },
            "definitions": {
                "User": {
                    "type": "object",
                    "properties": {
                        "id": { "type": "integer" },
                        "email": { "type": "string", "format": "email" }
                    }
                }
            },
            "paths": {
                "/api/users": {
                    "get": {
                        "produces": ["application/json"],
                        "responses": {
                            "200": {
                                "description": "OK",
                                "schema": { "$ref": "#/definitions/User" }
                            }
                        }
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates[0].responseBody != nil, "Should generate body from schema ref")
        let body = candidates[0].responseBody!
        #expect(body.contains("\"id\""))
        #expect(body.contains("user@example.com"))
    }

    // MARK: - Error Handling

    @Test("Throws on invalid JSON")
    func throwsOnInvalidJSON() async {
        let data = Data("not json".utf8)
        await #expect(throws: (any Error).self) {
            try await OpenAPIParser.parse(data: data)
        }
    }

    // MARK: - Swagger 2.0

    @Test("Parses a Swagger 2.0 spec")
    func parseSwagger2() async throws {
        // `basePath: "/v1"` rather than the `"/"` this carried, and every other `basePath` fixture
        // in the suite carried with it. `/` is the one value for which prepending the prefix and
        // dropping it produce the same string, so a suite that only ever wrote `/` could not see
        // that `basePath` was decoded and then read by nothing. See `ImportedRouteMatchingTests`.
        let spec = """
        {
            "swagger": "2.0",
            "info": { "title": "Test", "version": "1.0" },
            "basePath": "/v1",
            "paths": {
                "/api/users": {
                    "get": {
                        "operationId": "listUsers",
                        "summary": "List all users",
                        "produces": ["application/json"],
                        "responses": {
                            "200": {
                                "description": "Success"
                            }
                        }
                    },
                    "post": {
                        "summary": "Create user",
                        "responses": {
                            "201": { "description": "Created" }
                        }
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates.count == 2)
        let get = candidates.first { $0.method == .get }!
        #expect(get.path == "/v1/api/users", "the document's basePath is part of the route it serves")
        #expect(get.statusCode == 200)
        // The spec offers both `operationId: ListUsers` and `summary: "List all users"`, and the
        // summary wins: it is the sentence the spec's author wrote for a human, and this name becomes
        // the endpoint's label in the sidebar. This used to assert "ListUsers" — a raw camelCase
        // identifier shipped as a user-facing name.
        #expect(get.suggestedName == "List all users")
        #expect(get.responseContentType == .json)

        let post = candidates.first { $0.method == .post }!
        #expect(post.statusCode == 201)
    }

    @Test("Swagger 2.0 generates fallback body with description when no schema")
    func swagger2FallbackWithDescription() async throws {
        // This one keeps `"/"` on purpose. "A basePath of `/` adds nothing to the route" is a real
        // case and has to stay covered; it just cannot be the *only* case covered, which is what it
        // was — see `parseSwagger2` above and `ImportedRouteMatchingTests`.
        let spec = """
        {
            "swagger": "2.0",
            "info": { "title": "httpbin", "version": "0.9.2" },
            "basePath": "/",
            "definitions": {},
            "paths": {
                "/anything": {
                    "get": {
                        "produces": ["application/json"],
                        "responses": {
                            "200": {
                                "description": "Anything passed in request"
                            }
                        },
                        "summary": "Returns anything passed in request data."
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates.count == 1)
        #expect(candidates[0].responseBody != nil)
        #expect(candidates[0].responseBody!.contains("Anything passed in request"))
        #expect(candidates[0].responseContentType == .json)
    }

    @Test("Swagger 2.0 generates fallback body with path parameters")
    func swagger2FallbackWithParameters() async throws {
        let spec = """
        {
            "swagger": "2.0",
            "info": { "title": "httpbin", "version": "0.9.2" },
            "basePath": "/",
            "definitions": {},
            "paths": {
                "/basic-auth/{user}/{passwd}": {
                    "get": {
                        "produces": ["application/json"],
                        "parameters": [
                            { "in": "path", "name": "user", "type": "string" },
                            { "in": "path", "name": "passwd", "type": "string" }
                        ],
                        "responses": {
                            "200": {
                                "description": "Sucessful authentication."
                            }
                        }
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates.count == 1)
        let body = candidates[0].responseBody!
        #expect(body.contains("Sucessful authentication."))
        #expect(body.contains("\"user\""))
        #expect(body.contains("\"passwd\""))

        // This fixture carries two `{}` parameters and asserted only what ended up in the body. The
        // route it produced — three literal segments, one of them the string `{user}` — could not
        // answer the request the route describes, which is the thing an import exists to do.
        #expect(candidates[0].path == "/basic-auth/:user/:passwd")
        #expect(PathPattern.matches(requestPath: "/basic-auth/me/hunter2", pattern: candidates[0].path))
    }

    // MARK: - Status Code Selection

    @Test("Prefers 200 response over other status codes")
    func prefers200() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/data": {
                    "get": {
                        "responses": {
                            "404": { "description": "Not found" },
                            "200": { "description": "OK" },
                            "500": { "description": "Error" }
                        }
                    }
                }
            }
        }
        """
        let data = Data(spec.utf8)
        let candidates = try await OpenAPIParser.parse(data: data)

        #expect(candidates[0].statusCode == 200)
    }

    @Test("Uses plain text content when JSON content is unavailable")
    func usesPlainTextContentType() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/text": {
                    "get": {
                        "responses": {
                            "200": {
                                "description": "Plain text",
                                "content": {
                                    "text/plain": {
                                        "example": "pong"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        """
        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))

        #expect(candidates[0].responseContentType == .plainText)
        #expect(candidates[0].responseBody?.contains("pong") == true)
    }

    @Test("Resolves referenced examples from components")
    func resolvesReferencedExamples() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/example": {
                    "get": {
                        "responses": {
                            "200": {
                                "description": "OK",
                                "content": {
                                    "application/json": {
                                        "examples": {
                                            "ok": { "$ref": "#/components/examples/Success" }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            },
            "components": {
                "examples": {
                    "Success": {
                        "value": {
                            "status": "ready"
                        }
                    }
                }
            }
        }
        """
        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))

        #expect(candidates[0].responseBody?.contains("ready") == true)
    }

    @Test("Resolves referenced responses and falls back from external examples to schema")
    func resolvesReferencedResponsesAndFallsBackFromExternalExamples() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/component-response": {
                    "get": {
                        "responses": {
                            "200": {
                                "$ref": "#/components/responses/UserResponse"
                            }
                        }
                    }
                }
            },
            "components": {
                "responses": {
                    "UserResponse": {
                        "description": "OK",
                        "content": {
                            "application/json": {
                                "examples": {
                                    "remote": {
                                        "$ref": "#/components/examples/RemoteUser"
                                    }
                                },
                                "schema": {
                                    "type": "object",
                                    "properties": {
                                        "name": { "type": "string" },
                                        "active": { "type": "boolean" }
                                    }
                                }
                            }
                        }
                    }
                },
                "examples": {
                    "RemoteUser": {
                        "externalValue": "https://example.com/user.json"
                    }
                }
            }
        }
        """

        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))

        #expect(candidates[0].responseBody?.contains("\"name\"") == true)
        #expect(candidates[0].responseBody?.contains("\"active\"") == true)
    }

    @Test("Uses 2XX response range when explicit 200 is absent")
    func usesResponseRange() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/range": {
                    "get": {
                        "responses": {
                            "2XX": {
                                "description": "Wildcard success"
                            },
                            "404": {
                                "description": "Missing"
                            }
                        }
                    }
                }
            }
        }
        """
        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))

        #expect(candidates[0].statusCode == 200)
        #expect(candidates[0].responseBody?.contains("Wildcard success") == true)
    }

    @Test("Uses default responses when no explicit status code is available")
    func usesDefaultResponse() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/default": {
                    "get": {
                        "responses": {
                            "default": {
                                "description": "Default fallback"
                            }
                        }
                    }
                }
            }
        }
        """

        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))

        #expect(candidates[0].statusCode == 200)
        #expect(candidates[0].responseBody?.contains("Default fallback") == true)
    }

    @Test("Falls back to schema when inline examples only provide external values")
    func fallsBackFromInlineExternalExamplesToSchema() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/external-inline": {
                    "get": {
                        "responses": {
                            "200": {
                                "description": "OK",
                                "content": {
                                    "application/json": {
                                        "examples": {
                                            "remote": {
                                                "externalValue": "https://example.com/example.json"
                                            }
                                        },
                                        "schema": {
                                            "type": "object",
                                            "properties": {
                                                "status": { "type": "string" },
                                                "count": { "type": "integer" }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        """

        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))

        #expect(candidates[0].responseBody?.contains("\"status\"") == true)
        #expect(candidates[0].responseBody?.contains("\"count\"") == true)
    }

    @Test("Skips referenced path items that are not resolved")
    func skipsReferencedPathItems() async throws {
        let spec = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/users": {
                    "$ref": "#/components/pathItems/UserCollection"
                }
            }
        }
        """
        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))

        #expect(candidates.isEmpty)
    }

    @Test("Swagger 2.0 uses schema examples and first successful response")
    func swaggerUsesSchemaExamplesAndFallbackStatusSelection() async throws {
        let spec = """
        {
            "swagger": "2.0",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/files": {
                    "get": {
                        "produces": ["text/plain"],
                        "responses": {
                            "204": {
                                "description": "No content",
                                "schema": {
                                    "type": "string",
                                    "example": "done"
                                }
                            },
                            "500": {
                                "description": "Server error"
                            }
                        }
                    }
                }
            }
        }
        """
        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))

        #expect(candidates[0].statusCode == 204)
        #expect(candidates[0].responseContentType == .plainText)
        #expect(candidates[0].responseBody?.contains("done") == true)
    }

    @Test("Swagger 2.0 uses non-JSON examples when application/json is absent")
    func swaggerUsesFirstAvailableExample() async throws {
        let spec = """
        {
            "swagger": "2.0",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/export": {
                    "get": {
                        "responses": {
                            "200": {
                                "description": "Export",
                                "examples": {
                                    "text/plain": "csv,data"
                                }
                            }
                        }
                    }
                }
            }
        }
        """
        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))

        #expect(candidates[0].responseBody?.contains("csv,data") == true)
        // This document declares no `produces` at all — not on the operation, not at the top. That
        // used to import as `.plainText`; it is now JSON, which is what the body already was:
        // `AnyCodableValue.toJSONString()` runs the example through `JSONEncoder`.
        #expect(candidates[0].responseContentType == .json)
    }

    // MARK: - Content types as real specs declare them

    /// Every Swagger fixture above puts `produces` inside the operation. Real specs overwhelmingly
    /// declare it once at the document level, which this parser did not decode at all — so those
    /// specs imported as plain text, which then short-circuited the JSON body fallback and left every
    /// endpoint with no body either. Two bugs, one missing field, and fixtures tidier than reality.
    @Test("A document-level `produces` applies to operations that do not override it")
    func swagger2HonoursDocumentLevelProduces() async throws {
        let spec = """
        {
            "swagger": "2.0",
            "info": { "title": "Test", "version": "1.0" },
            "produces": ["application/json"],
            "paths": {
                "/api/users": {
                    "get": {
                        "operationId": "listUsers",
                        "summary": "List all users",
                        "responses": { "200": { "description": "A list of users" } }
                    }
                },
                "/api/report": {
                    "get": {
                        "produces": ["text/csv"],
                        "responses": { "200": { "description": "A CSV report" } }
                    }
                }
            }
        }
        """
        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))
        let users = try #require(candidates.first { $0.path == "/api/users" })
        let report = try #require(candidates.first { $0.path == "/api/report" })

        #expect(users.responseContentType == .json)
        #expect(users.responseBody != nil, "a JSON endpoint with no schema still gets a fallback body")
        // An operation's own `produces` still wins over the document's.
        #expect(report.responseContentType == .plainText)
    }

    /// The other half of the same miss, and the same pair of bugs. Swagger 2 gives `produces` no
    /// default and a spec may omit it entirely; `swagger2ContentType` answered `.plainText` for that
    /// (`?? []`, then an empty `contains`), and `parseSwagger2` reaches for the fallback body only
    /// when the content type is `.json` — so the spec that says least imported with the wrong
    /// content type *and* no body at all.
    @Test("A spec that declares no `produces` anywhere imports as JSON, with a body")
    func swagger2DefaultsToJSONWhenNothingIsDeclared() async throws {
        let spec = """
        {
            "swagger": "2.0",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/users": {
                    "get": {
                        "summary": "List all users",
                        "responses": { "200": { "description": "A list of users" } }
                    }
                }
            }
        }
        """
        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))
        let candidate = try #require(candidates.first)

        #expect(candidate.responseContentType == .json)
        #expect(candidate.responseBody != nil, "`.plainText` here also short-circuits the fallback body")
    }

    /// `application/json` is not the only spelling of JSON, and both of these appear in specs that
    /// ship. The exact-match test this replaced imported them as plain text.
    @Test(
        "JSON is recognised by more than an exact `application/json`",
        arguments: ["application/json", "application/hal+json", "application/json; charset=utf-8", "application/vnd.api+json"]
    )
    func swagger2RecognisesJSONVariants(mimeType: String) async throws {
        let spec = """
        {
            "swagger": "2.0",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/api/users": {
                    "get": {
                        "produces": ["\(mimeType)"],
                        "responses": { "200": { "description": "A list of users" } }
                    }
                }
            }
        }
        """
        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))
        let candidate = try #require(candidates.first)
        #expect(candidate.responseContentType == .json)
    }

    /// Swagger 2 candidates used to be constructed by hand instead of going through
    /// `ImportCandidateBuilder`, so they carried their own duplicate rule — one that compared route
    /// only, while the shared rule also compares the GraphQL operation. The header policy was skipped
    /// on that path too. `ImportHeaderPolicyTests` claimed to cover "every importer" and could not:
    /// it called the builder directly.
    @Test("Swagger 2 candidates are built by the same chokepoint as every other importer")
    func swagger2UsesTheSharedBuilder() async throws {
        let spec = """
        {
            "swagger": "2.0",
            "info": { "title": "Test", "version": "1.0" },
            "produces": ["application/json"],
            "paths": {
                "/api/users": {
                    "get": { "responses": { "200": { "description": "OK" } } }
                }
            }
        }
        """
        let existing = Endpoint(
            name: "Users",
            method: .get,
            path: "/api/users",
            scenarios: [],
            activeScenarioID: nil
        )
        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8), existingEndpoints: [existing])
        let candidate = try #require(candidates.first)

        #expect(candidate.isDuplicate)
        #expect(candidate.isSelected == false, "a duplicate arrives unselected")
        // The builder names and groups a candidate when the parser does not.
        #expect(candidate.suggestedGroupTag != nil)
    }
}
