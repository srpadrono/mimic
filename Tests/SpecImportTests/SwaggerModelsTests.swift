import Testing
import Foundation
@testable import SpecImport

@Suite("Swagger Models")
struct SwaggerModelsTests {
    @Test("An explicit null schema example remains distinct from a missing example")
    func explicitNullExampleIsPreserved() throws {
        let schemas = try JSONDecoder().decode([SwaggerSchemaObject].self, from: Data("""
        [{ "example": null }, {}]
        """.utf8))

        try #require(schemas.count == 2)
        let example = try #require(schemas[0].example)
        #expect(example.toJSONString() == "null")
        #expect(schemas[1].example == nil)
    }

    @Test("Swagger enums decode numeric, boolean, and null values without converting them to strings")
    func enumValuesPreserveJSONTypes() throws {
        let schemas = try JSONDecoder().decode([SwaggerSchemaObject].self, from: Data("""
        [
            { "type": "integer", "enum": [7, 9] },
            { "type": "boolean", "enum": [false, true] },
            { "enum": [null, "fallback"] }
        ]
        """.utf8))

        try #require(schemas.count == 3)
        #expect(schemas[0].enumValues?.map { $0.toJSONString() } == ["7", "9"])
        #expect(schemas[1].enumValues?.map { $0.toJSONString() } == ["false", "true"])
        #expect(schemas[2].enumValues?.map { $0.toJSONString() } == ["null", "\"fallback\""])
    }

    @Test("Local Swagger references decode URI and JSON Pointer escapes once")
    func localReferencesDecodeOneComponentName() {
        let references = [
            ("#/responses/Ready", "Ready"),
            ("#/responses/a~1b", "a/b"),
            ("#/responses/a~0b", "a~b"),
            ("#/responses/a~01b", "a~1b"),
            ("#/responses/a%20b", "a b"),
            ("#/responses/%E2%9C%93", "✓"),
            ("#/responses/a%7E1b", "a/b"),
            ("#/responses/a~1\u{0301}b", "a/\u{0301}b"),
            ("#/responses/a~0\u{0301}b", "a~\u{0301}b"),
            ("#/responses/%CC%81name", "\u{0301}name"),
        ]
        for (reference, name) in references {
            let decoded = SwaggerReference.localName(reference, section: "responses")
            #expect(decoded?.unicodeScalars.elementsEqual(name.unicodeScalars) == true)
        }
        #expect(SwaggerReference.localName("#/definitions/Account", section: "definitions") == "Account")
    }

    @Test("Swagger component references reject external URLs, nested pointers, and malformed escapes")
    func invalidLocalReferencesAreRefused() {
        for reference in [
            "https://example.com/api.json#/responses/Ready", "other.json#/responses/Ready",
            "#/definitions/Ready", "#/responses/parent/child", "#/responses/parent%2Fchild",
            "#/responses/Bad~2name", "#/responses/Bad~", "#/responses/Bad%", "#/responses/%FF",
            "#/responses/a~\u{0301}b", "#/responses/a/\u{0301}b", "#\u{0301}/responses/name",
        ] {
            #expect(SwaggerReference.localName(reference, section: "responses") == nil)
        }
    }

    @Test("AnyCodableValue encodes collections to JSON strings")
    func anyCodableValueEncodesCollections() {
        let arrayJSON = AnyCodableValue.array([.int(1), .string("two")]).toJSONString()
        let objectJSON = AnyCodableValue.object([
            "status": .string("ok"),
            "count": .int(2),
        ]).toJSONString()

        #expect(arrayJSON?.contains("two") == true)
        #expect(objectJSON?.contains("\"status\"") == true)
        #expect(objectJSON?.contains("\"ok\"") == true)
    }

    @Test("Swagger document decodes nested schema properties")
    func swaggerDocumentDecodesNestedSchemaProperties() throws {
        let json = """
        {
            "swagger": "2.0",
            "info": {
                "title": "Inventory",
                "version": "1.0"
            },
            "basePath": "/inventory/v1",
            "paths": {
                "/items": {
                    "get": {
                        "operationId": "listItems",
                        "summary": "List items",
                        "responses": {
                            "200": {
                                "description": "OK",
                                "schema": {
                                    "type": "object",
                                    "properties": {
                                        "items": {
                                            "type": "array",
                                            "items": {
                                                "type": "string"
                                            }
                                        }
                                    }
                                },
                                "examples": {
                                    "application/json": {
                                        "items": ["a", "b"]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        """

        let document = try JSONDecoder().decode(SwaggerDocument.self, from: Data(json.utf8))

        #expect(document.swagger == "2.0")
        #expect(document.info?.title == "Inventory")
        // Decoded since this model was written, and asserted by nothing until now — which is how it
        // went on being read by nothing for as long as it did. A non-`/` value, so the assertion
        // says something: `/` is the value every `basePath` fixture in this suite used to carry.
        #expect(document.basePath == "/inventory/v1")
        #expect(document.paths?["/items"]?.get?.responses?["200"]?.description == "OK")
        #expect(document.paths?["/items"]?.get?.responses?["200"]?.schema?.properties?["items"]?.items?.type == "string")
        #expect(document.paths?["/items"]?.get?.responses?["200"]?.examples?["application/json"]?.toJSONString()?.contains("\"items\"") == true)
    }

    @Test("AnyCodableValue decodes nulls and scalar variants")
    func anyCodableValueDecodesScalarVariants() throws {
        let json = """
        {
            "nullValue": null,
            "boolValue": true,
            "doubleValue": 3.14,
            "arrayValue": [1, "two"],
            "objectValue": { "nested": false }
        }
        """

        let decoded = try JSONDecoder().decode([String: AnyCodableValue].self, from: Data(json.utf8))

        if case .null = decoded["nullValue"] {
        } else {
            Issue.record("Expected null value to decode as .null")
        }

        if case .bool(true) = decoded["boolValue"] {
        } else {
            Issue.record("Expected bool value to decode as .bool(true)")
        }

        if case .double(let value) = decoded["doubleValue"] {
            #expect(value == 3.14)
        } else {
            Issue.record("Expected double value to decode as .double")
        }

        if case .array(let values) = decoded["arrayValue"] {
            #expect(values.count == 2)
        } else {
            Issue.record("Expected array value to decode as .array")
        }

        if case .object(let object) = decoded["objectValue"] {
            #expect(object["nested"]?.toJSONString()?.contains("false") == true)
        } else {
            Issue.record("Expected object value to decode as .object")
        }
    }
}
