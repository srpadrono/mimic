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
        let spec = """
        {
            "swagger": "2.0",
            "info": { "title": "Test", "version": "1.0" },
            "basePath": "/",
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
        #expect(get.path == "/api/users")
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
    }
}
