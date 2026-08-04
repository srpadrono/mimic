import Foundation
import OpenAPIKit30

/// Generates placeholder JSON examples from OpenAPI/Swagger schemas.
enum SchemaExampleGenerator {

    /// Maximum recursion depth to prevent infinite loops on circular schemas.
    static let maxDepth = 3

    // MARK: - OpenAPI 3.x (JSONSchema)

    /// Generate a placeholder value from an OpenAPI 3.x JSONSchema.
    /// Returns nil if the schema can't produce a meaningful example.
    static func generate(from schema: JSONSchema, in document: OpenAPI.Document? = nil, depth: Int = 0) -> Any? {
        guard depth < maxDepth else { return nil }

        // Check for explicit example first
        if let example = schema.example {
            return example.value
        }

        switch schema.value {
        case .boolean:
            return schema.allowedValues?.first?.value ?? false

        case .integer:
            if let first = schema.allowedValues?.first?.value { return first }
            return 0

        case .number:
            if let first = schema.allowedValues?.first?.value { return first }
            return 0.0

        case .string(let context, _):
            if let first = schema.allowedValues?.first?.value as? String { return first }
            return placeholderForStringFormat(context.format.rawValue)

        case .object(_, let objectContext):
            var dict: [String: Any] = [:]
            for (key, propSchema) in objectContext.properties {
                if let value = generate(from: propSchema, in: document, depth: depth + 1) {
                    dict[key] = value
                }
            }
            return dict.isEmpty ? nil : dict

        case .array(_, let arrayContext):
            if let itemSchema = arrayContext.items {
                if let itemValue = generate(from: itemSchema, in: document, depth: depth + 1) {
                    return [itemValue]
                }
            }
            return [] as [Any]

        case .reference(let ref, _):
            guard let document else { return nil }
            if let resolved = try? document.components.lookup(ref) {
                return generate(from: resolved, in: document, depth: depth + 1)
            }
            return nil

        case .all(of: let schemas, core: _):
            var merged: [String: Any] = [:]
            for sub in schemas {
                if let obj = generate(from: sub, in: document, depth: depth + 1) as? [String: Any] {
                    merged.merge(obj) { _, new in new }
                }
            }
            return merged.isEmpty ? nil : merged

        case .one(of: let schemas, core: _), .any(of: let schemas, core: _):
            if let first = schemas.first {
                return generate(from: first, in: document, depth: depth + 1)
            }
            return nil

        case .not, .fragment:
            return nil
        }
    }

    /// Convert a generated value to a pretty-printed JSON string.
    static func toJSONString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) else {
            // Primitive value — use JSONEncoder for safe escaping
            if let str = value as? String {
                if let data = try? JSONEncoder().encode(str) {
                    return String(data: data, encoding: .utf8)
                }
                return "\"\(str)\""
            }
            return "\(value)"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Fallback Generation (no schema)

    /// Generate a placeholder JSON body from Swagger 2.0 operation metadata.
    static func generateFallbackBody(
        description: String?,
        parameters: [SwaggerParameter]?
    ) -> String? {
        var dict: [String: Any] = [:]

        if let desc = description, !desc.isEmpty {
            dict["message"] = desc
        }

        if let params = parameters {
            for param in params {
                guard let name = param.name else { continue }
                guard let location = param.in, location == "path" || location == "query" else { continue }

                if let defaultVal = param.default {
                    dict[name] = defaultVal.toNativeValue()
                    continue
                }

                dict[name] = placeholderForType(param.type, format: param.format)
            }
        }

        guard !dict.isEmpty else { return "{}" }
        return toJSONString(dict)
    }

    /// Generate a placeholder JSON body from OpenAPI 3.x operation context.
    static func generateFallbackBody(
        description: String?,
        parameters: [OpenAPI.Parameter]
    ) -> String? {
        var dict: [String: Any] = [:]

        if let desc = description, !desc.isEmpty {
            dict["message"] = desc
        }

        for param in parameters {
            guard param.context.inPath || param.context.inQuery else { continue }
            let name = param.name

            if let schema = param.schemaOrContent.schemaValue {
                if let generated = generateFromSimpleSchema(schema) {
                    dict[name] = generated
                    continue
                }
            }
            dict[name] = "string"
        }

        guard !dict.isEmpty else { return "{}" }
        return toJSONString(dict)
    }

    // MARK: - Swagger 2.0

    /// Generate a placeholder value from a Swagger 2.0 schema definition.
    static func generate(from schema: SwaggerSchemaObject, definitions: [String: SwaggerSchemaObject]?, depth: Int = 0) -> Any? {
        guard depth < maxDepth else { return nil }

        if let example = schema.example {
            return example.toNativeValue()
        }

        // Handle $ref
        if let ref = schema.ref {
            let name = ref.replacingOccurrences(of: "#/definitions/", with: "")
            if let resolved = definitions?[name] {
                return generate(from: resolved, definitions: definitions, depth: depth + 1)
            }
            return nil
        }

        switch schema.type {
        case "string":
            if let first = schema.enumValues?.first { return first }
            return placeholderForStringFormat(schema.format)

        case "integer", "int32", "int64":
            return 0

        case "number", "float", "double":
            return 0.0

        case "boolean":
            return false

        case "object":
            var dict: [String: Any] = [:]
            if let properties = schema.properties {
                for (key, propSchema) in properties {
                    if let value = generate(from: propSchema, definitions: definitions, depth: depth + 1) {
                        dict[key] = value
                    }
                }
            }
            return dict.isEmpty ? nil : dict

        case "array":
            if let items = schema.items {
                if let itemValue = generate(from: items, definitions: definitions, depth: depth + 1) {
                    return [itemValue]
                }
            }
            return [] as [Any]

        default:
            // If no type but has properties, treat as object
            if let properties = schema.properties, !properties.isEmpty {
                var dict: [String: Any] = [:]
                for (key, propSchema) in properties {
                    if let value = generate(from: propSchema, definitions: definitions, depth: depth + 1) {
                        dict[key] = value
                    }
                }
                return dict.isEmpty ? nil : dict
            }
            return nil
        }
    }

    // MARK: - Private Helpers

    /// Single source of truth for string format → placeholder value mapping.
    private static func placeholderForStringFormat(_ format: String?) -> String {
        switch format {
        case "date-time": return "2024-01-01T00:00:00Z"
        case "date": return "2024-01-01"
        case "email": return "user@example.com"
        case "uri", "url": return "https://example.com"
        case "uuid": return "00000000-0000-0000-0000-000000000000"
        default: return "string"
        }
    }

    /// Map a Swagger 2.0 type + format to a placeholder value.
    private static func placeholderForType(_ type: String?, format: String?) -> Any {
        switch type {
        case "integer", "int32", "int64": return 0
        case "number", "float", "double": return 0.0
        case "boolean": return false
        case "string": return placeholderForStringFormat(format)
        default: return "string"
        }
    }

    /// Generate a placeholder from a simple (non-object, non-array) JSONSchema for parameter fallbacks.
    private static func generateFromSimpleSchema(_ schema: JSONSchema) -> Any? {
        switch schema.value {
        case .boolean: return false
        case .integer: return 0
        case .number: return 0.0
        case .string(let ctx, _):
            if let first = schema.allowedValues?.first?.value as? String { return first }
            return placeholderForStringFormat(ctx.format.rawValue)
        default: return nil
        }
    }
}

// MARK: - AnyCodableValue helpers

extension AnyCodableValue {
    func toNativeValue() -> Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .array(let v): return v.map { $0.toNativeValue() }
        case .object(let v): return v.mapValues { $0.toNativeValue() }
        case .null: return NSNull()
        }
    }
}
