import Foundation

// MARK: - Swagger 2.0 Codable Models

/// Root Swagger 2.0 document.
struct SwaggerDocument: Codable, Sendable {
    let swagger: String?
    let info: SwaggerInfo?
    let basePath: String?
    let paths: [String: SwaggerPathItem]?
    let definitions: [String: SwaggerSchemaObject]?
}

struct SwaggerInfo: Codable, Sendable {
    let title: String?
    let version: String?
}

struct SwaggerPathItem: Codable, Sendable {
    let get: SwaggerOperation?
    let post: SwaggerOperation?
    let put: SwaggerOperation?
    let patch: SwaggerOperation?
    let delete: SwaggerOperation?
    let head: SwaggerOperation?
    let options: SwaggerOperation?
}

struct SwaggerOperation: Codable, Sendable {
    let operationId: String?
    let summary: String?
    let tags: [String]?
    let produces: [String]?
    let parameters: [SwaggerParameter]?
    let responses: [String: SwaggerResponse]?
}

struct SwaggerParameter: Codable, Sendable {
    let name: String?
    let `in`: String?
    let type: String?
    let format: String?
    let `default`: AnyCodableValue?
}

struct SwaggerResponse: Codable, Sendable {
    let description: String?
    let schema: SwaggerSchemaObject?
    let examples: [String: AnyCodableValue]?
}

/// Full Swagger 2.0 schema object supporting properties, items, $ref, enum, format.
/// Uses a class to allow recursive structure (items, properties).
final class SwaggerSchemaObject: Codable, Sendable {
    let type: String?
    let format: String?
    let ref: String?
    let properties: [String: SwaggerSchemaObject]?
    let items: SwaggerSchemaObject?
    let enumValues: [String]?
    let example: AnyCodableValue?

    enum CodingKeys: String, CodingKey {
        case type, format, properties, items, example
        case ref = "$ref"
        case enumValues = "enum"
    }
}

/// Lightweight any-value wrapper for Swagger examples.
enum AnyCodableValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([AnyCodableValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: AnyCodableValue].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    func toJSONString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
