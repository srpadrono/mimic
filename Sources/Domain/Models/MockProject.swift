import Foundation

public struct MockProject: Identifiable, Codable, Sendable, Equatable {
    /// Bumped to 2 when journeys were added. Older documents decode with an empty journey list.
    public static let currentSchemaVersion: Int = 2

    public let id: UUID
    public let schemaVersion: Int
    public var name: String
    public var serverConfiguration: ServerConfiguration
    public var endpoints: [Endpoint]
    /// Every journey stored with the project. Many may exist at once; at most one is active.
    public var journeys: [Journey]
    /// The journey currently overlaying endpoint resolution, or `nil` for plain endpoint mocking.
    public var activeJourneyID: UUID?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        serverConfiguration: ServerConfiguration = .default,
        endpoints: [Endpoint] = [],
        journeys: [Journey] = [],
        activeJourneyID: UUID? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = MockProject.currentSchemaVersion
        self.name = name
        self.serverConfiguration = serverConfiguration
        self.endpoints = endpoints
        self.journeys = journeys
        self.activeJourneyID = activeJourneyID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// The active journey, if the id still resolves to a stored journey. A dangling
    /// `activeJourneyID` reads as "no journey" rather than failing — deleting the active journey is
    /// a normal edit, not an error state.
    public var activeJourney: Journey? {
        guard let activeJourneyID else { return nil }
        return journeys.first { $0.id == activeJourneyID }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, name, serverConfiguration, endpoints, journeys, activeJourneyID
        case createdAt, modifiedAt
    }

    /// Hand-written so v1 documents — exported before journeys existed — still decode. Anything the
    /// older schema lacks decodes to its empty value rather than throwing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? MockProject.currentSchemaVersion
        name = try container.decode(String.self, forKey: .name)
        serverConfiguration = try container.decodeIfPresent(
            ServerConfiguration.self,
            forKey: .serverConfiguration
        ) ?? .default
        endpoints = try container.decodeIfPresent([Endpoint].self, forKey: .endpoints) ?? []
        journeys = try container.decodeIfPresent([Journey].self, forKey: .journeys) ?? []
        activeJourneyID = try container.decodeIfPresent(UUID.self, forKey: .activeJourneyID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
    }
}
