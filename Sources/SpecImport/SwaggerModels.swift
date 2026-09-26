import Foundation

// MARK: - Swagger 2.0 Codable Models

/// Root Swagger 2.0 document.
struct SwaggerDocument: Codable, Sendable {
    let swagger: String?
    let info: SwaggerInfo?
    let basePath: String?
    /// Document-level content types, which an operation may override with its own `produces`.
    ///
    /// Swagger 2 permits both, and real specs overwhelmingly declare it once at the top rather than
    /// on every operation — this was not decoded at all, so those specs imported every endpoint as
    /// plain text, which then short-circuited the JSON body fallback and left them with no body
    /// either. Every fixture in the test suite happened to put `produces` inside the operation.
    let produces: [String]?
    let paths: [String: SwaggerPathItem]?
    let definitions: [String: SwaggerSchemaObject]?
    let responses: [String: SwaggerResponse]?
}

struct SwaggerInfo: Codable, Sendable {
    let title: String?
    let version: String?
}

struct SwaggerPathItem: Codable, Sendable {
    let ref: String?
    let get: SwaggerOperation?
    let post: SwaggerOperation?
    let put: SwaggerOperation?
    let patch: SwaggerOperation?
    let delete: SwaggerOperation?
    let head: SwaggerOperation?
    let options: SwaggerOperation?

    enum CodingKeys: String, CodingKey {
        case ref = "$ref"
        case get, post, put, patch, delete, head, options
    }
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
    let ref: String?
    let description: String?
    let schema: SwaggerSchemaObject?
    let examples: [String: AnyCodableValue]?

    enum CodingKeys: String, CodingKey {
        case ref = "$ref"
        case description, schema, examples
    }
}

/// Swagger 2.0 schema subset used for examples: properties, items, $ref, enum, and format.
/// Uses a class to allow recursive structure (items, properties).
final class SwaggerSchemaObject: Codable, Sendable {
    let type: String?
    let format: String?
    let ref: String?
    let properties: [String: SwaggerSchemaObject]?
    let items: SwaggerSchemaObject?
    let enumValues: [AnyCodableValue]?
    let example: AnyCodableValue?

    enum CodingKeys: String, CodingKey {
        case type, format, properties, items, example
        case ref = "$ref"
        case enumValues = "enum"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        ref = try container.decodeIfPresent(String.self, forKey: .ref)
        properties = try container.decodeIfPresent([String: SwaggerSchemaObject].self, forKey: .properties)
        items = try container.decodeIfPresent(SwaggerSchemaObject.self, forKey: .items)
        enumValues = try container.decodeIfPresent([AnyCodableValue].self, forKey: .enumValues)
        // A JSON null is an explicit example, distinct from an absent example. The synthesized
        // optional decoder uses decodeIfPresent and loses that distinction before generation.
        if container.contains(.example) {
            example = try container.decode(AnyCodableValue.self, forKey: .example)
        } else {
            example = nil
        }
    }
}

/// Resolves one name beneath a known local component section. References use URI-fragment
/// percent encoding followed by JSON Pointer escaping; a nested pointer is not a component name.
enum SwaggerReference {
    static func localName(_ reference: String, section: String) -> String? {
        guard reference.unicodeScalars.first == "#",
              let pointer = String(String.UnicodeScalarView(reference.unicodeScalars.dropFirst())).removingPercentEncoding
        else { return nil }
        let parts = pointer.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1].elementsEqual(section.unicodeScalars) else { return nil }

        var name = ""
        var scalars = parts[2].makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "~" else {
                name.unicodeScalars.append(scalar)
                continue
            }
            switch scalars.next() {
            case "0": name.unicodeScalars.append("~")
            case "1": name.unicodeScalars.append("/")
            default: return nil
            }
        }
        return name
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
