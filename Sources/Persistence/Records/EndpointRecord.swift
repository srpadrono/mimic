import GRDB
import Domain
import Foundation

/// GRDB record bridging Endpoint domain models to the "endpoint" database table.
public struct EndpointRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "endpoint"

    public var id: String
    public var projectID: String
    public var name: String
    public var method: String
    public var path: String
    public var activeScenarioID: String?
    public var delayMs: Int
    public var groupTag: String?
    public var graphqlOperation: String?
    public var backendID: String?
    public var sortOrder: Int

    /// Creates an EndpointRecord from a domain Endpoint and its parent project ID.
    public init(from endpoint: Endpoint, projectID: String, sortOrder: Int = 0) {
        self.id = endpoint.id.uuidString
        self.projectID = projectID
        self.name = endpoint.name
        self.method = endpoint.method.rawValue
        self.path = endpoint.path
        self.activeScenarioID = endpoint.activeScenarioID?.uuidString
        self.delayMs = endpoint.delayMs
        self.groupTag = endpoint.groupTag
        self.graphqlOperation = endpoint.graphqlOperation
        self.backendID = endpoint.backendID?.uuidString
        self.sortOrder = sortOrder
    }

    /// Converts the record back to a domain Endpoint with the provided scenarios.
    public func toDomain(scenarios: [Scenario]) throws -> Endpoint {
        let endpointID = try PersistenceError.requiredUUID(
            id, table: Self.databaseTableName, id: id, field: "id"
        )
        _ = try PersistenceError.requiredUUID(
            projectID, table: Self.databaseTableName, id: id, field: "projectID"
        )
        guard let httpMethod = HTTPMethod(rawValue: method) else {
            throw PersistenceError.corruptedRecord(table: Self.databaseTableName, id: id, field: "method")
        }
        let activeID = try PersistenceError.optionalUUID(
            activeScenarioID, table: Self.databaseTableName, id: id, field: "activeScenarioID"
        )
        let backend = try PersistenceError.optionalUUID(
            backendID, table: Self.databaseTableName, id: id, field: "backendID"
        )
        return Endpoint(
            id: endpointID,
            name: name,
            method: httpMethod,
            path: path,
            scenarios: scenarios,
            activeScenarioID: activeID,
            delayMs: delayMs,
            groupTag: groupTag,
            graphqlOperation: graphqlOperation,
            backendID: backend
        )
    }
}
