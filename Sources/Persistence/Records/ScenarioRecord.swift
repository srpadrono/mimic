import GRDB
import Domain
import Foundation

/// GRDB record bridging Scenario domain models to the "scenario" database table.
/// The headers dictionary is stored as a JSON string in the headersJSON column.
public struct ScenarioRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "scenario"

    public var id: String
    public var endpointID: String
    public var name: String
    public var statusCode: Int
    public var headersJSON: String
    public var body: String?
    public var bodyContentType: String
    public var sortOrder: Int

    /// Creates a ScenarioRecord from a domain Scenario and its parent endpoint ID.
    public init(from scenario: Scenario, endpointID: String, sortOrder: Int = 0) {
        self.id = scenario.id.uuidString
        self.endpointID = endpointID
        self.name = scenario.name
        self.statusCode = scenario.statusCode
        self.headersJSON = HeaderCoding.encode(scenario.headers)
        self.body = scenario.body
        self.bodyContentType = scenario.bodyContentType.rawValue
        self.sortOrder = sortOrder
    }

    /// Converts the record back to a domain Scenario, decoding the headers JSON.
    public func toDomain() throws -> Scenario {
        let scenarioID = try PersistenceError.requiredUUID(
            id, table: Self.databaseTableName, id: id, field: "id"
        )
        _ = try PersistenceError.requiredUUID(
            endpointID, table: Self.databaseTableName, id: id, field: "endpointID"
        )
        guard let contentType = Scenario.ContentType(rawValue: bodyContentType) else {
            throw PersistenceError.corruptedRecord(table: Self.databaseTableName, id: id, field: "bodyContentType")
        }
        return try Scenario(
            id: scenarioID,
            name: name,
            statusCode: statusCode,
            headers: HeaderCoding.decode(headersJSON, table: Self.databaseTableName, id: id),
            body: body,
            bodyContentType: contentType
        )
    }
}

/// Headers are a small string map; storing them as JSON in one column keeps the schema flat and the
/// round-trip lossless. A corrupt cell must fail a load before an autosave can erase those headers.
enum HeaderCoding {
    static func encode(_ headers: [String: String]) -> String {
        guard !headers.isEmpty,
              let data = try? JSONEncoder().encode(headers),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    static func decode(_ json: String, table: String, id: String) throws -> [String: String] {
        do {
            return try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        } catch {
            throw PersistenceError.corruptedRecord(table: table, id: id, field: "headersJSON")
        }
    }
}
