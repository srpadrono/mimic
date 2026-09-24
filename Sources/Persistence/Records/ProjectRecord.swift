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
    public var upstreamURL: String?
    public var backendsJSON: String
    public var primaryName: String
    public var passthroughEnabled: Bool
    public var captureResponses: Bool
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
        self.upstreamURL = project.serverConfiguration.upstreamURL
        self.backendsJSON = String(data: (try? JSONEncoder().encode(project.serverConfiguration.backends)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        self.primaryName = project.serverConfiguration.primaryName
        self.passthroughEnabled = project.serverConfiguration.passthroughEnabled
        self.captureResponses = project.serverConfiguration.captureResponses
        self.activeJourneyID = project.activeJourneyID?.uuidString
    }

    /// Refuses a row written by a build that understands a later document schema than this one.
    ///
    /// `schemaVersion` was write-only. `init(from:)` stores `project.schemaVersion`, but `toDomain`
    /// rebuilds through `MockProject`'s memberwise initialiser, which hard-codes
    /// `MockProject.currentSchemaVersion` — so the column round-tripped a *constant*. A project
    /// written by a future Mimic loaded as a current one, having silently dropped whatever that
    /// version added, and the next autosave wrote the lower number back over it. That is the exact
    /// failure the field exists to prevent, and reading it here is the only reading it has ever had.
    ///
    /// `ProjectValidator.validate` makes the same check on the import path, where a *foreign*
    /// document arrives, and says in as many words that it cannot cover a store written by a newer
    /// build: "Closing that is Persistence's to do, not this type's." This is that.
    ///
    /// Refusing rather than repairing, because a document from ahead of us cannot be read down
    /// safely: the fields we do not know about are exactly the ones that would be lost, and a load
    /// that half-succeeds is how the data actually goes missing. The caller gets a message naming
    /// both versions instead.
    public func requireSupportedSchemaVersion() throws {
        guard schemaVersion > MockProject.currentSchemaVersion else { return }
        throw PersistenceError.unsupportedSchemaVersion(
            name: name,
            stored: schemaVersion,
            supported: MockProject.currentSchemaVersion
        )
    }

    /// Converts the record back to a domain MockProject.
    /// Note: endpoints and journeys are populated by the repository layer, not here.
    ///
    /// The project this returns reports `MockProject.currentSchemaVersion` and not the stored
    /// number, because the memberwise initialiser stamps it and that initialiser belongs to Domain.
    /// On the path that matters — `load`, the one that hands a project to the app to edit and save —
    /// that is a migration rather than a relabelling, because `load` calls
    /// `requireSupportedSchemaVersion()` first: nothing from ahead of this build gets that far, and a
    /// row from behind it genuinely *is* the current shape once loaded (v2 added journeys, and a v1
    /// project has none), which the next save writes back as the current number. `allProjects` uses
    /// `toListingDomain()` instead, so unreadable backend configuration cannot hide every project.
    ///
    /// Carrying the stored integer through unchanged would need a `schemaVersion:` parameter on
    /// `MockProject.init`, which is a change to Domain rather than to this record.
    public func toDomain() throws -> MockProject {
        let projectID = try PersistenceError.requiredUUID(id, table: Self.databaseTableName, id: id, field: "id")
        let activeID = try PersistenceError.optionalUUID(activeJourneyID, table: Self.databaseTableName, id: id, field: "activeJourneyID")
        let backends: [BackendConfiguration]
        do {
            backends = try JSONDecoder().decode([BackendConfiguration].self, from: Data(backendsJSON.utf8))
        } catch {
            throw PersistenceError.corruptedRecord(table: Self.databaseTableName, id: id, field: "backendsJSON")
        }
        return MockProject(
            id: projectID,
            name: name,
            serverConfiguration: ServerConfiguration(
                port: serverPort,
                globalDelayMs: globalDelayMs,
                upstreamURL: upstreamURL,
                backends: backends, primaryName: primaryName, passthroughEnabled: passthroughEnabled, captureResponses: captureResponses
            ),
            endpoints: [],
            journeys: [],
            activeJourneyID: activeID,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    /// A list entry remains visible even when a backend configuration prevents the full project
    /// from opening. A malformed active selection is omitted from the listing; the full load still
    /// refuses it. The returned project is a display stub and must never be saved as a document.
    public func toListingDomain() throws -> MockProject {
        let projectID = try PersistenceError.requiredUUID(id, table: Self.databaseTableName, id: id, field: "id")
        let activeID = activeJourneyID.flatMap(UUID.init(uuidString:))
        return MockProject(
            id: projectID,
            name: name,
            serverConfiguration: ServerConfiguration(
                port: serverPort,
                globalDelayMs: globalDelayMs,
                upstreamURL: upstreamURL,
                backends: [], primaryName: primaryName, passthroughEnabled: passthroughEnabled, captureResponses: captureResponses
            ),
            endpoints: [],
            journeys: [],
            activeJourneyID: activeID,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }
}
