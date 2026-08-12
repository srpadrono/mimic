import Testing
import Foundation
@testable import SpecImport

@Suite("Swagger Models")
struct SwaggerModelsTests {
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
            "basePath": "/",
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
