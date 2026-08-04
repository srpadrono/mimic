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
        self.sortOrder = sortOrder
    }

    /// Converts the record back to a domain Endpoint with the provided scenarios.
    public func toDomain(scenarios: [Scenario]) -> Endpoint {
        Endpoint(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            method: HTTPMethod(rawValue: method) ?? .get,
            path: path,
            scenarios: scenarios,
            activeScenarioID: activeScenarioID.flatMap { UUID(uuidString: $0) },
            delayMs: delayMs,
            groupTag: groupTag,
            graphqlOperation: graphqlOperation
        )
    }
}
