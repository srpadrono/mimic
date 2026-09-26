import Foundation
import OpenAPIKit30

/// Generates placeholder JSON examples from OpenAPI/Swagger schemas.
enum SchemaExampleGenerator {

    /// Maximum JSON nesting for synthesized examples; references and compositions do not add depth.
    static let maxDepth = 3
    /// References do not add JSON nesting, but their traversal still needs a finite work budget.
    private static let maxSchemaVisits = 128
    private static let maxGeneratedStringLength = 1_024

    // MARK: - OpenAPI 3.x (JSONSchema)

    /// Generate a placeholder value from an OpenAPI 3.x JSONSchema.
    /// Returns nil if the schema can't produce a meaningful example.
    static func generate(from schema: JSONSchema, in document: OpenAPI.Document? = nil, depth: Int = 0) -> Any? {
        var remainingVisits = maxSchemaVisits
        return generate(from: schema, in: document, depth: depth, remainingVisits: &remainingVisits)
    }

    private static func generate(
        from schema: JSONSchema, in document: OpenAPI.Document?, depth: Int,
        remainingVisits: inout Int
    ) -> Any? {
        guard depth >= 0, depth < maxDepth, remainingVisits > 0 else { return nil }
        remainingVisits -= 1

        // Check for explicit example first
        if let example = schema.example {
            return declaredValue(example.value)
        }
        if let value = schema.defaultValue { return declaredValue(value.value) }
        if let values = schema.allowedValues {
            guard let first = values.first else { return nil }
            return declaredValue(first.value)
        }

        switch schema.value {
        case .boolean:
            return false

        case .integer(_, let context):
            return integerPlaceholder(context)

        case .number(_, let context):
            return numberPlaceholder(context)

        case .string(let core, let context):
            return stringPlaceholder(format: core.format.rawValue, context: context)

        case .object(_, let objectContext):
            var dict: [String: Any] = [:]
            // Required response properties get the budget first. writeOnly requirements apply
            // to requests, so their values must not be invented in an imported response.
            let properties = objectContext.properties.sorted {
                if $0.value.required != $1.value.required { return $0.value.required }
                return $0.key < $1.key
            }
            for (key, propSchema) in properties {
                guard let property = resolvedSchema(propSchema, in: document, remainingVisits: &remainingVisits) else {
                    if propSchema.required { return nil }
                    continue
                }
                guard !property.writeOnly else { continue }
                if let value = generate(from: property, in: document, depth: depth + 1,
                    remainingVisits: &remainingVisits) {
                    dict[key] = value
                } else if property.nullable, property.allowedValues == nil {
                    dict[key] = NSNull()
                } else if propSchema.required {
                    return nil
                }
            }
            return dict.isEmpty ? nil : dict

        case .array(_, let arrayContext):
            // A single-item preview cannot satisfy a larger minimum. Leave such a schema to
            // the review fallback rather than allocating an attacker-chosen repetition count.
            guard arrayContext.minItems >= 0, arrayContext.minItems <= 1,
                  arrayContext.maxItems.map({ $0 >= arrayContext.minItems }) ?? true else { return nil }
            if arrayContext.maxItems == 0 { return [] as [Any] }
            if let itemSchema = arrayContext.items {
                if let itemValue = generate(from: itemSchema, in: document, depth: depth + 1,
                    remainingVisits: &remainingVisits) {
                    return [itemValue]
                }
            }
            return arrayContext.minItems == 0 ? [] as [Any] : nil

        case .reference:
            if let resolved = resolvedSchema(schema, in: document, remainingVisits: &remainingVisits) {
                return generate(from: resolved, in: document, depth: depth, remainingVisits: &remainingVisits)
            }
            return nil

        case .all(of: let schemas, core: _):
            var merged: [String: Any] = [:]
            for sub in schemas {
                guard let obj = generate(from: sub, in: document, depth: depth,
                    remainingVisits: &remainingVisits) as? [String: Any] else { return nil }
                for (key, value) in obj {
                    if let existing = merged[key], toJSONString(existing) != toJSONString(value) { return nil }
                    merged[key] = value
                }
            }
            return merged.isEmpty ? nil : merged

        case .one(of: let schemas, core: _):
            guard let first = schemas.first,
                  let selected = resolvedSchema(first, in: document, remainingVisits: &remainingVisits),
                  let value = generate(from: selected, in: document, depth: depth,
                    remainingVisits: &remainingVisits),
                  let serialized = toJSONString(value) else { return nil }
            for alternative in schemas.dropFirst() {
                guard remainingVisits > 0 else { return nil }
                remainingVisits -= 1
                guard let other = resolvedSchema(alternative, in: document, remainingVisits: &remainingVisits) else { return nil }
                if let values = other.allowedValues {
                    guard !values.contains(where: { toJSONString(declaredValue($0.value)) == serialized }) else { return nil }
                } else {
                    // Without an instance validator, only disjoint types establish exclusivity.
                    // Integers also match number schemas, and nullable branches can share null.
                    guard let selectedType = selected.jsonType, let otherType = other.jsonType,
                          selectedType != otherType,
                          !(selected.isInteger && other.isNumber), !(selected.isNumber && other.isInteger),
                          !(value is NSNull && other.nullable) else { return nil }
                }
            }
            return value

        case .any(of: let schemas, core: _):
            for sub in schemas {
                if let value = generate(from: sub, in: document, depth: depth,
                    remainingVisits: &remainingVisits) { return value }
            }
            return nil

        case .not, .fragment:
            return nil
        }
    }

    /// Convert a generated value to a pretty-printed JSON string.
    static func toJSONString(_ value: Any) -> String? {
        // A generated example can be a top-level scalar, including NSNull from a Swagger example.
        // String interpolation turns NSNull into "<null>". Foundation raises an Objective-C
        // exception for non-finite numbers, so validate the entire value in an array first; this
        // also accepts scalar roots, unlike isValidJSONObject(value) itself.
        guard JSONSerialization.isValidJSONObject([value]) else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]
        ) else {
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
        var remainingVisits = maxSchemaVisits
        return generate(from: schema, definitions: definitions, depth: depth, remainingVisits: &remainingVisits)
    }

    private static func generate(
        from schema: SwaggerSchemaObject, definitions: [String: SwaggerSchemaObject]?, depth: Int,
        remainingVisits: inout Int
    ) -> Any? {
        guard depth >= 0, depth < maxDepth, remainingVisits > 0 else { return nil }
        remainingVisits -= 1

        if let example = schema.example {
            return example.toNativeValue()
        }

        // Handle $ref
        if let ref = schema.ref {
            if let name = SwaggerReference.localName(ref, section: "definitions"),
               let resolved = definitions?[name] {
                return generate(from: resolved, definitions: definitions, depth: depth,
                    remainingVisits: &remainingVisits)
            }
            return nil
        }
        if let values = schema.enumValues {
            return values.first?.toNativeValue()
        }

        switch schema.type {
        case "string":
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
                for (key, propSchema) in properties.sorted(by: { $0.key < $1.key }) {
                    if let value = generate(from: propSchema, definitions: definitions, depth: depth + 1,
                        remainingVisits: &remainingVisits) {
                        dict[key] = value
                    }
                }
            }
            return dict.isEmpty ? nil : dict

        case "array":
            if let items = schema.items {
                if let itemValue = generate(from: items, definitions: definitions, depth: depth + 1,
                    remainingVisits: &remainingVisits) {
                    return [itemValue]
                }
            }
            return [] as [Any]

        default:
            // If no type but has properties, treat as object
            if let properties = schema.properties, !properties.isEmpty {
                var dict: [String: Any] = [:]
                for (key, propSchema) in properties.sorted(by: { $0.key < $1.key }) {
                    if let value = generate(from: propSchema, definitions: definitions, depth: depth + 1,
                        remainingVisits: &remainingVisits) {
                        dict[key] = value
                    }
                }
                return dict.isEmpty ? nil : dict
            }
            return nil
        }
    }

    // MARK: - Private Helpers

    /// OpenAPIKit can represent declared nulls as Void, including nullable string enum members.
    private static func declaredValue(_ value: Any) -> Any {
        if value is Void { return NSNull() }
        if let array = value as? [Any?] { return array.map { $0.map(declaredValue) ?? NSNull() } }
        if let object = value as? [String: Any?] { return object.mapValues { $0.map(declaredValue) ?? NSNull() } }
        return value
    }

    private static func resolvedSchema(
        _ schema: JSONSchema, in document: OpenAPI.Document?, remainingVisits: inout Int
    ) -> JSONSchema? {
        var resolved = schema
        while case .reference(let reference, _) = resolved.value {
            guard remainingVisits > 0, let document,
                  let next = try? document.components.lookup(reference) else { return nil }
            remainingVisits -= 1
            resolved = next
        }
        return resolved
    }

    private static func integerPlaceholder(_ context: JSONSchema.IntegerContext) -> Int? {
        var lower = context.minimum?.value ?? Int.min
        var upper = context.maximum?.value ?? Int.max
        if context.minimum?.exclusive == true {
            let next = lower.addingReportingOverflow(1)
            guard !next.overflow else { return nil }
            lower = next.partialValue
        }
        if context.maximum?.exclusive == true {
            let previous = upper.subtractingReportingOverflow(1)
            guard !previous.overflow else { return nil }
            upper = previous.partialValue
        }
        guard lower <= upper else { return nil }
        var value = min(max(0, lower), upper)
        if let multiple = context.multipleOf {
            guard multiple > 0 else { return nil }
            let remainder = value % multiple
            if remainder != 0 {
                // Zero is preferred when allowed; otherwise round away from zero into the
                // permitted interval, with checked arithmetic at the machine integer limits.
                let adjustment = value > 0 ? multiple - remainder : -(multiple + remainder)
                let rounded = value.addingReportingOverflow(adjustment)
                guard !rounded.overflow else { return nil }
                value = rounded.partialValue
            }
        }
        return (lower...upper).contains(value) ? value : nil
    }

    private static func numberPlaceholder(_ context: JSONSchema.NumericContext) -> Double? {
        var lower = context.minimum?.value ?? -.greatestFiniteMagnitude
        var upper = context.maximum?.value ?? .greatestFiniteMagnitude
        if context.minimum?.exclusive == true { lower = lower.nextUp }
        if context.maximum?.exclusive == true { upper = upper.nextDown }
        guard lower.isFinite, upper.isFinite, lower <= upper else { return nil }
        let value = min(max(0, lower), upper)
        if let multiple = context.multipleOf {
            guard multiple.isFinite, multiple > 0 else { return nil }
            // Avoid pretending binary floating-point rounding proves decimal multipleOf.
            // Zero is exact for every positive multiple; other values need an explicit example.
            guard value == 0 else { return nil }
        }
        return value
    }

    private static func stringPlaceholder(format: String?, context: JSONSchema.StringContext) -> String? {
        guard context.minLength >= 0, context.minLength <= maxGeneratedStringLength,
              context.maxLength.map({ $0 >= context.minLength }) ?? true else { return nil }
        // Arbitrary regex synthesis is outside a bounded placeholder generator. In particular,
        // do not run an untrusted backtracking expression against a generated padded string.
        guard context.pattern == nil else { return nil }
        let preferred = placeholderForStringFormat(format)
        if ["date-time", "date", "email", "uri", "url", "uuid"].contains(format ?? "") {
            guard preferred.count >= context.minLength,
                  context.maxLength.map({ preferred.count <= $0 }) ?? true else { return nil }
            return preferred
        }
        let shortened = String(preferred.prefix(context.maxLength ?? preferred.count))
        return shortened + String(repeating: "a", count: max(0, context.minLength - shortened.count))
    }

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
        case .boolean, .integer, .number, .string: return generate(from: schema)
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
