import GRDB
import Domain
import Foundation

/// GRDB record bridging MockProject domain models to the "project" database table.
public struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "project"

    public var id: String
    public var schemaVersion: Int
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var serverPort: Int
    public var globalDelayMs: Int
    public var activeJourneyID: String?

    /// Creates a ProjectRecord from a domain MockProject.
    public init(from project: MockProject) {
        self.id = project.id.uuidString
        self.schemaVersion = project.schemaVersion
        self.name = project.name
        self.createdAt = project.createdAt
        self.modifiedAt = project.modifiedAt
        self.serverPort = project.serverConfiguration.port
        self.globalDelayMs = project.serverConfiguration.globalDelayMs
        self.activeJourneyID = project.activeJourneyID?.uuidString
    }

    /// Converts the record back to a domain MockProject.
    /// Note: endpoints and journeys are populated by the repository layer, not here.
    public func toDomain() -> MockProject {
        MockProject(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            serverConfiguration: ServerConfiguration(
                port: serverPort,
                globalDelayMs: globalDelayMs
            ),
            endpoints: [],
            journeys: [],
            activeJourneyID: activeJourneyID.flatMap { UUID(uuidString: $0) },
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }
}
