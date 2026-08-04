import Testing
import Foundation
import OpenAPIKit30
@testable import SpecImport

@Suite("SchemaExampleGenerator")
struct SchemaExampleGeneratorTests {

    // MARK: - Swagger 2.0 Schema Generation

    @Test func generatesStringPlaceholder() {
        let schema = SwaggerSchemaObject.make(type: "string")
        let result = SchemaExampleGenerator.generate(from: schema, definitions: nil)
        #expect(result as? String == "string")
    }

    @Test func generatesIntegerPlaceholder() {
        let schema = SwaggerSchemaObject.make(type: "integer")
        let result = SchemaExampleGenerator.generate(from: schema, definitions: nil)
        #expect(result as? Int == 0)
    }

    @Test func generatesNumberPlaceholder() {
        let schema = SwaggerSchemaObject.make(type: "number")
        let result = SchemaExampleGenerator.generate(from: schema, definitions: nil)
        #expect(result as? Double == 0.0)
    }

    @Test func generatesBooleanPlaceholder() {
        let schema = SwaggerSchemaObject.make(type: "boolean")
        let result = SchemaExampleGenerator.generate(from: schema, definitions: nil)
        #expect(result as? Bool == false)
    }

    @Test func generatesEmailFormatPlaceholder() {
        let schema = SwaggerSchemaObject.make(type: "string", format: "email")
        let result = SchemaExampleGenerator.generate(from: schema, definitions: nil)
        #expect(result as? String == "user@example.com")
    }

    @Test func generatesDateTimeFormatPlaceholder() {
        let schema = SwaggerSchemaObject.make(type: "string", format: "date-time")
        let result = SchemaExampleGenerator.generate(from: schema, definitions: nil)
        #expect(result as? String == "2024-01-01T00:00:00Z")
    }

    @Test func generatesUUIDFormatPlaceholder() {
        let schema = SwaggerSchemaObject.make(type: "string", format: "uuid")
        let result = SchemaExampleGenerator.generate(from: schema, definitions: nil)
        #expect(result as? String == "00000000-0000-0000-0000-000000000000")
    }

    @Test func usesEnumFirstValue() {
        let schema = SwaggerSchemaObject.make(type: "string", enumValues: ["active", "inactive"])
        let result = SchemaExampleGenerator.generate(from: schema, definitions: nil)
        #expect(result as? String == "active")
    }

    @Test func usesExplicitExample() {
        let schema = SwaggerSchemaObject.make(type: "string", example: .string("custom"))
        let result = SchemaExampleGenerator.generate(from: schema, definitions: nil)
        #expect(result as? String == "custom")
    }

    @Test func generatesObjectFromProperties() {
        let props: [String: SwaggerSchemaObject] = [
            "name": .make(type: "string"),
            "age": .make(type: "integer"),
        ]
        let schema = SwaggerSchemaObject.make(type: "object", properties: props)
        let result = SchemaExampleGenerator.generate(from: schema, definitions: nil) as? [String: Any]
        #expect(result?["name"] as? String == "string")
        #expect(result?["age"] as? Int == 0)
    }

    @Test func generatesArrayWithItems() {
        let itemSchema = SwaggerSchemaObject.make(type: "string")
        let schema = SwaggerSchemaObject.make(type: "array", items: itemSchema)
        let result = SchemaExampleGenerator.generate(from: schema, definitions: nil) as? [Any]
        #expect(result?.count == 1)
        #expect(result?.first as? String == "string")
    }

    @Test func resolvesRefFromDefinitions() {
        let userSchema = SwaggerSchemaObject.make(type: "object", properties: [
            "id": .make(type: "integer"),
        ])
        let refSchema = SwaggerSchemaObject.make(ref: "#/definitions/User")
        let result = SchemaExampleGenerator.generate(from: refSchema, definitions: ["User": userSchema])
        let dict = result as? [String: Any]
        #expect(dict?["id"] as? Int == 0)
    }

    @Test func swaggerUnresolvedReferencesAndImplicitObjects() {
        let unresolved = SwaggerSchemaObject.make(ref: "#/definitions/Missing")
        #expect(SchemaExampleGenerator.generate(from: unresolved, definitions: [:]) == nil)

        let implicitObject = SwaggerSchemaObject.make(properties: [
            "name": .make(type: "string"),
            "active": .make(type: "boolean"),
        ])
        let result = SchemaExampleGenerator.generate(from: implicitObject, definitions: nil) as? [String: Any]
        #expect(result?["name"] as? String == "string")
        #expect(result?["active"] as? Bool == false)
    }

    @Test func stopsAtMaxDepth() {
        // Create a self-referencing schema via definitions
        let selfRef = SwaggerSchemaObject.make(type: "object", properties: [
            "child": .make(ref: "#/definitions/Node"),
        ])
        let result = SchemaExampleGenerator.generate(from: selfRef, definitions: ["Node": selfRef], depth: SchemaExampleGenerator.maxDepth)
        #expect(result == nil)
    }

    @Test func emptyArrayWhenNoItems() {
        let schema = SwaggerSchemaObject.make(type: "array")
        let result = SchemaExampleGenerator.generate(from: schema, definitions: nil) as? [Any]
        #expect(result?.isEmpty == true)
    }

    // MARK: - toJSONString

    @Test func toJSONStringHandlesDict() {
        let dict: [String: Any] = ["key": "value"]
        let result = SchemaExampleGenerator.toJSONString(dict)
        #expect(result != nil)
        #expect(result!.contains("\"key\""))
        #expect(result!.contains("\"value\""))
    }

    @Test func toJSONStringHandlesPrimitiveString() {
        let result = SchemaExampleGenerator.toJSONString("hello")
        #expect(result == "\"hello\"")
    }

    @Test func toJSONStringHandlesNumber() {
        let result = SchemaExampleGenerator.toJSONString(42)
        #expect(result == "42")
    }

    // MARK: - Fallback body generation

    @Test func fallbackBodyWithDescription() {
        let body = SchemaExampleGenerator.generateFallbackBody(
            description: "Success response",
            parameters: nil as [SwaggerParameter]?
        )
        #expect(body != nil)
        #expect(body!.contains("Success response"))
    }

    @Test func fallbackBodyWithParameters() {
        let params = [
            SwaggerParameter.make(name: "userId", in: "path", type: "integer"),
            SwaggerParameter.make(name: "format", in: "query", type: "string"),
        ]
        let body = SchemaExampleGenerator.generateFallbackBody(description: nil, parameters: params)
        #expect(body != nil)
        #expect(body!.contains("\"userId\""))
        #expect(body!.contains("\"format\""))
    }

    @Test func fallbackBodyEmptyReturnsEmptyObject() {
        let body = SchemaExampleGenerator.generateFallbackBody(
            description: nil,
            parameters: nil as [SwaggerParameter]?
        )
        #expect(body == "{}")
    }

    @Test func fallbackBodySkipsBodyParameters() {
        let params = [
            SwaggerParameter.make(name: "body", in: "body", type: "object"),
        ]
        let body = SchemaExampleGenerator.generateFallbackBody(description: nil, parameters: params)
        #expect(body == "{}")
    }

    @Test func fallbackBodyUsesSwaggerDefaultValuesAndFormats() {
        let params = [
            SwaggerParameter.make(name: "status", in: "query", type: "string", defaultValue: .string("ok")),
            SwaggerParameter.make(name: "callback", in: "query", type: "string", format: "uri"),
            SwaggerParameter.make(name: "admin", in: "path", type: "boolean"),
        ]
        let body = SchemaExampleGenerator.generateFallbackBody(description: "Done", parameters: params)

        #expect(body?.contains("\"status\"") == true)
        #expect(body?.contains("\"ok\"") == true)
        #expect(body?.contains("\"callback\"") == true)
        #expect(body?.contains("\"admin\"") == true)
    }

    @Test func fallbackBodyUsesAdditionalFormatsAndEmptyOpenAPIFallbacks() throws {
        let swaggerParams = [
            SwaggerParameter.make(name: "birthday", in: "query", type: "string", format: "date"),
            SwaggerParameter.make(name: "homepage", in: "query", type: "string", format: "url"),
        ]
        let swaggerBody = SchemaExampleGenerator.generateFallbackBody(description: nil, parameters: swaggerParams)
        #expect(swaggerBody?.contains("2024-01-01") == true)
        #expect(swaggerBody?.contains("example.com") == true)

        let openAPIParams = [
            try OpenAPI.Parameter.make("""
            {
              "name": "trace",
              "in": "header",
              "required": false,
              "schema": { "type": "string" }
            }
            """),
        ]
        #expect(SchemaExampleGenerator.generateFallbackBody(description: nil, parameters: openAPIParams) == "{}")
    }

    // MARK: - OpenAPI 3.x Schema Generation

    @Test func openAPIGeneratesPrimitiveAndArrayPlaceholders() throws {
        let uriSchema = try JSONSchema.make(#"{"type":"string","format":"uri"}"#)
        let integerSchema = try JSONSchema.make(#"{"type":"integer","enum":[7,9]}"#)
        let numberSchema = try JSONSchema.make(#"{"type":"number","enum":[3.14]}"#)
        let booleanSchema = try JSONSchema.make(#"{"type":"boolean","enum":[true,false]}"#)
        let arraySchema = try JSONSchema.make(#"{"type":"array","items":{"type":"string","enum":["alpha"]}}"#)

        #expect(SchemaExampleGenerator.generate(from: uriSchema) as? String == "https://example.com")
        #expect(SchemaExampleGenerator.generate(from: integerSchema) as? Int == 7)
        #expect(SchemaExampleGenerator.generate(from: numberSchema) as? Double == 3.14)
        #expect(SchemaExampleGenerator.generate(from: booleanSchema) as? Bool == true)

        let arrayValue = SchemaExampleGenerator.generate(from: arraySchema) as? [Any]
        #expect(arrayValue?.count == 1)
        #expect(arrayValue?.first as? String == "alpha")
    }

    @Test func openAPIGeneratesComposedSchemas() throws {
        let allOf = try JSONSchema.make("""
        {
            "allOf": [
                {
                    "type": "object",
                    "properties": {
                        "id": { "type": "integer" }
                    }
                },
                {
                    "type": "object",
                    "properties": {
                        "email": { "type": "string", "format": "email" }
                    }
                }
            ]
        }
        """)
        let oneOf = try JSONSchema.make(#"{"oneOf":[{"type":"string","enum":["ready"]},{"type":"integer"}]}"#)
        let anyOf = try JSONSchema.make(#"{"anyOf":[{"type":"number"},{"type":"string"}]}"#)

        let generatedUser = SchemaExampleGenerator.generate(from: allOf) as? [String: Any]
        #expect(generatedUser?["id"] as? Int == 0)
        #expect(generatedUser?["email"] as? String == "user@example.com")
        #expect(SchemaExampleGenerator.generate(from: oneOf) as? String == "ready")
        #expect(SchemaExampleGenerator.generate(from: anyOf) as? Double == 0.0)
    }

    @Test func openAPIReferenceWithoutDocumentReturnsNil() throws {
        let refSchema = try JSONSchema.make(##"{"$ref":"#/components/schemas/User"}"##)

        #expect(SchemaExampleGenerator.generate(from: refSchema, in: nil) == nil)
    }

    @Test func openAPIUsesExplicitExampleAndHandlesUnsupportedForms() throws {
        let explicit = try JSONSchema.make(#"{"type":"string","example":"ready"}"#)
        let emptyObject = try JSONSchema.make(#"{"type":"object","properties":{}}"#)
        let emptyArray = try JSONSchema.make(#"{"type":"array"}"#)
        let emptyOneOf = try JSONSchema.make(#"{"oneOf":[]}"#)
        let emptyAnyOf = try JSONSchema.make(#"{"anyOf":[]}"#)
        let notSchema = try JSONSchema.make(#"{"not":{"type":"string"}}"#)
        let badReference = try JSONSchema.make(##"{"$ref":"#/components/schemas/Missing"}"##)
        let document = try OpenAPI.Document.make("""
        {
          "openapi": "3.0.0",
          "info": { "title": "Fixture", "version": "1.0.0" },
          "paths": {},
          "components": { "schemas": {} }
        }
        """)

        #expect(SchemaExampleGenerator.generate(from: explicit) as? String == "ready")
        #expect(SchemaExampleGenerator.generate(from: emptyObject) == nil)
        #expect((SchemaExampleGenerator.generate(from: emptyArray) as? [Any])?.isEmpty == true)
        #expect(SchemaExampleGenerator.generate(from: emptyOneOf) == nil)
        #expect(SchemaExampleGenerator.generate(from: emptyAnyOf) == nil)
        #expect(SchemaExampleGenerator.generate(from: notSchema) == nil)
        #expect(SchemaExampleGenerator.generate(from: badReference, in: document) == nil)
    }

    @Test func openAPIGeneratesFallbackBodyFromParameters() throws {
        let params = [
            try OpenAPI.Parameter.make("""
            {
                "name": "id",
                "in": "path",
                "required": true,
                "schema": { "type": "integer" }
            }
            """),
            try OpenAPI.Parameter.make("""
            {
                "name": "callback",
                "in": "query",
                "required": false,
                "schema": { "type": "string", "format": "uri" }
            }
            """),
            try OpenAPI.Parameter.make("""
            {
                "name": "filter",
                "in": "query",
                "required": false,
                "schema": {
                    "type": "object",
                    "properties": {
                        "status": { "type": "string" }
                    }
                }
            }
            """),
            try OpenAPI.Parameter.make("""
            {
                "name": "trace",
                "in": "header",
                "required": false,
                "schema": { "type": "string" }
            }
            """),
        ]
        let body = SchemaExampleGenerator.generateFallbackBody(description: "Fetched user", parameters: params)

        #expect(body?.contains("Fetched user") == true)
        #expect(body?.contains("\"id\"") == true)
        #expect(body?.contains("\"callback\"") == true)
        #expect(body?.contains("\"filter\"") == true)
        #expect(body?.contains("\"trace\"") == false)
    }

    // MARK: - AnyCodableValue

    @Test func anyCodableValueRoundTrips() throws {
        let values: [AnyCodableValue] = [
            .string("hello"),
            .int(42),
            .double(3.14),
            .bool(true),
            .null,
            .array([.int(1), .string("two")]),
            .object(["key": .bool(false)]),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(AnyCodableValue.self, from: data)
            let original = try encoder.encode(value)
            let roundTripped = try encoder.encode(decoded)
            #expect(original == roundTripped)
        }
    }

    @Test func anyCodableToNativeValue() {
        #expect(AnyCodableValue.string("hi").toNativeValue() as? String == "hi")
        #expect(AnyCodableValue.int(5).toNativeValue() as? Int == 5)
        #expect(AnyCodableValue.double(1.5).toNativeValue() as? Double == 1.5)
        #expect(AnyCodableValue.bool(true).toNativeValue() as? Bool == true)
        #expect(AnyCodableValue.null.toNativeValue() is NSNull)
    }

    @Test func anyCodableValueToJSONString() {
        let object = AnyCodableValue.object([
            "ok": .bool(true),
            "count": .int(2),
        ])

        let json = object.toJSONString()

        #expect(json?.contains("\"ok\"") == true)
        #expect(json?.contains("true") == true)
        #expect(json?.contains("\"count\"") == true)
    }
}

// MARK: - Test Helpers

extension SwaggerSchemaObject {
    static func make(
        type: String? = nil,
        format: String? = nil,
        ref: String? = nil,
        properties: [String: SwaggerSchemaObject]? = nil,
        items: SwaggerSchemaObject? = nil,
        enumValues: [String]? = nil,
        example: AnyCodableValue? = nil
    ) -> SwaggerSchemaObject {
        let json: [String: Any?] = [
            "type": type,
            "format": format,
            "$ref": ref,
            "enum": enumValues,
        ]
        // Build via Codable since all properties are let
        var jsonDict: [String: Any] = [:]
        for (k, v) in json { if let v { jsonDict[k] = v } }

        // Use direct decoding approach
        let data = try! JSONSerialization.data(withJSONObject: jsonDict)
        let schema = try! JSONDecoder().decode(SwaggerSchemaObject.self, from: data)

        // For properties/items/example we need to use a fuller JSON
        if properties != nil || items != nil || example != nil {
            var fullDict: [String: Any] = jsonDict
            if let props = properties {
                var propsJson: [String: Any] = [:]
                for (k, v) in props {
                    let propData = try! JSONEncoder().encode(v)
                    propsJson[k] = try! JSONSerialization.jsonObject(with: propData)
                }
                fullDict["properties"] = propsJson
            }
            if let items = items {
                let itemData = try! JSONEncoder().encode(items)
                fullDict["items"] = try! JSONSerialization.jsonObject(with: itemData, options: [.fragmentsAllowed])
            }
            if let example = example {
                let exData = try! JSONEncoder().encode(example)
                fullDict["example"] = try! JSONSerialization.jsonObject(with: exData, options: [.fragmentsAllowed])
            }
            let fullData = try! JSONSerialization.data(withJSONObject: fullDict)
            return try! JSONDecoder().decode(SwaggerSchemaObject.self, from: fullData)
        }

        return schema
    }
}

extension SwaggerParameter {
    static func make(
        name: String,
        in location: String,
        type: String,
        format: String? = nil,
        defaultValue: AnyCodableValue? = nil
    ) -> SwaggerParameter {
        var json: [String: Any] = ["name": name, "in": location, "type": type]
        if let format {
            json["format"] = format
        }
        if let defaultValue {
            let defaultData = try! JSONEncoder().encode(defaultValue)
            json["default"] = try! JSONSerialization.jsonObject(with: defaultData, options: [.fragmentsAllowed])
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(SwaggerParameter.self, from: data)
    }
}

extension JSONSchema {
    static func make(_ json: String) throws -> JSONSchema {
        try JSONDecoder().decode(JSONSchema.self, from: Data(json.utf8))
    }
}

extension OpenAPI.Document {
    static func make(_ json: String) throws -> OpenAPI.Document {
        try JSONDecoder().decode(OpenAPI.Document.self, from: Data(json.utf8))
    }
}

extension OpenAPI.Parameter {
    static func make(_ json: String) throws -> OpenAPI.Parameter {
        try JSONDecoder().decode(OpenAPI.Parameter.self, from: Data(json.utf8))
    }
}
