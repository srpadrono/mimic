import Testing
import Foundation
@testable import SpecImport
import Domain

/// OpenAPI 3.1 and 3.2 documents, which the 3.0-only decoder refused with "Failed to parse
/// Document Version 3.1.0" before reading a single path. 3.1 is what FastAPI emits by default.
@Suite("OpenAPI 3.1 and 3.2 import")
struct OpenAPI31ImportTests {

    private func object(_ body: String?) throws -> [String: Any] {
        let data = try #require(body?.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("A 3.1 document imports, with 3.1-only schema keywords shaping the generated body")
    func importsOpenAPI31() async throws {
        let spec = """
        {
          "openapi": "3.1.0",
          "info": { "title": "Airports", "version": "1.1" },
          "paths": {
            "/api/airport/{iata}": {
              "get": {
                "summary": "One airport",
                "responses": {
                  "200": {
                    "description": "The airport",
                    "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Airport" } } }
                  },
                  "404": { "description": "No such code" }
                }
              }
            }
          },
          "components": {
            "schemas": {
              "Airport": {
                "type": "object",
                "required": ["iata", "name", "runways"],
                "properties": {
                  "iata": { "type": "string", "examples": ["AMS"] },
                  "name": { "type": ["string", "null"] },
                  "runways": { "type": "integer", "exclusiveMinimum": 0 }
                }
              }
            }
          }
        }
        """
        let candidates = try await OpenAPIParser.parse(data: Data(spec.utf8))
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.path == "/api/airport/:iata")
        #expect(candidate.statusCode == 200)
        #expect(candidate.suggestedName == "One airport")
        let body = try object(candidate.responseBody)
        #expect(body["iata"] as? String == "AMS")
        #expect(body["name"] as? String == "string")
        #expect(body["runways"] as? Int == 1)
    }

    @Test("A 3.1 named example is used as written")
    func usesOpenAPI31NamedExample() async throws {
        let spec = """
        {
          "openapi": "3.1.1",
          "info": { "title": "Examples", "version": "1" },
          "paths": {
            "/status": {
              "get": {
                "responses": {
                  "200": {
                    "description": "OK",
                    "content": { "application/json": { "examples": { "ready": { "value": { "state": "ready" } } } } }
                  }
                }
              }
            }
          }
        }
        """
        let candidate = try #require(try await OpenAPIParser.parse(data: Data(spec.utf8)).first)
        #expect(try object(candidate.responseBody)["state"] as? String == "ready")
    }

    @Test("A 3.2 example's dataValue becomes the response body")
    func usesOpenAPI32DataValue() async throws {
        let spec = """
        {
          "openapi": "3.2.0",
          "info": { "title": "Examples", "version": "1" },
          "paths": {
            "/status": {
              "get": {
                "responses": {
                  "200": {
                    "description": "OK",
                    "content": { "application/json": { "examples": { "ready": { "dataValue": { "state": "ready" } } } } }
                  }
                }
              }
            }
          }
        }
        """
        let candidate = try #require(try await OpenAPIParser.parse(data: Data(spec.utf8)).first)
        #expect(try object(candidate.responseBody)["state"] as? String == "ready")
    }

    @Test("A 3.2 example's serializedValue is served as written, even beside a dataValue")
    func prefersOpenAPI32SerializedValue() async throws {
        let spec = #"""
        {
          "openapi": "3.2.0",
          "info": { "title": "Examples", "version": "1" },
          "paths": {
            "/status": {
              "get": {
                "responses": {
                  "200": {
                    "description": "OK",
                    "content": { "application/json": { "examples": { "ready": {
                      "dataValue": { "state": "ready" },
                      "serializedValue": "{\"state\":\"ready\"}"
                    } } } }
                  }
                }
              }
            }
          }
        }
        """#
        let candidate = try #require(try await OpenAPIParser.parse(data: Data(spec.utf8)).first)
        #expect(candidate.responseBody == #"{"state":"ready"}"#)
    }

    @Test("A 3.1 route with a suffix after its parameter imports as written and answers requests")
    func importsPartialSegmentRouteFrom31() async throws {
        let spec = """
        {
          "openapi": "3.1.0",
          "info": { "title": "Airports", "version": "1.1" },
          "paths": {
            "/api/airport/{iata}.json": {
              "get": {
                "parameters": [{ "name": "iata", "in": "path", "required": true, "schema": { "type": "string" } }],
                "responses": { "200": { "description": "The airport" } }
              }
            }
          }
        }
        """
        let candidate = try #require(try await OpenAPIParser.parse(data: Data(spec.utf8)).first)
        #expect(candidate.path == "/api/airport/{iata}.json")
        // Named after the resource, not the template, when the spec offers no summary.
        #expect(candidate.suggestedName == "Get Airport")
        #expect(PathPattern.matches(requestPath: "/api/airport/LHR.json", pattern: candidate.path))
        #expect(!PathPattern.matches(requestPath: "/api/airport/LHR", pattern: candidate.path))
    }
}
