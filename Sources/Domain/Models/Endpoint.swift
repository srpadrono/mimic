import Foundation

public struct Endpoint: Identifiable, Codable, Sendable, Equatable {

    private enum CodingKeys: String, CodingKey {
        case id, name, method, path, scenarios, activeScenarioID, delayMs, groupTag, graphqlOperation
    }

    public let id: UUID
    public var name: String
    public var method: HTTPMethod
    public var path: String
    public var scenarios: [Scenario]
    public var activeScenarioID: UUID?
    public var delayMs: Int
    public var groupTag: String?
    /// Matches only requests asking for this GraphQL operation.
    ///
    /// GraphQL routes everything through one path, so method and path cannot tell two calls apart.
    /// An endpoint that names an operation matches only that one; an endpoint that names none still
    /// matches anything, which keeps a bare `POST /graphql` working as a catch-all.
    public var graphqlOperation: String?

    public init(
        id: UUID = UUID(),
        name: String,
        method: HTTPMethod = .get,
        path: String,
        scenarios: [Scenario] = [],
        activeScenarioID: UUID? = nil,
        delayMs: Int = 0,
        groupTag: String? = nil,
        graphqlOperation: String? = nil
    ) {
        self.id = id
        self.name = name
        self.method = method
        self.path = path
        self.scenarios = scenarios
        self.activeScenarioID = activeScenarioID
        self.delayMs = delayMs
        self.groupTag = groupTag
        self.graphqlOperation = graphqlOperation
    }

    /// Hand-written so documents exported before GraphQL matching existed still decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        method = try container.decodeIfPresent(HTTPMethod.self, forKey: .method) ?? .get
        path = try container.decode(String.self, forKey: .path)
        scenarios = try container.decodeIfPresent([Scenario].self, forKey: .scenarios) ?? []
        activeScenarioID = try container.decodeIfPresent(UUID.self, forKey: .activeScenarioID)
        delayMs = try container.decodeIfPresent(Int.self, forKey: .delayMs) ?? 0
        groupTag = try container.decodeIfPresent(String.self, forKey: .groupTag)
        graphqlOperation = try container.decodeIfPresent(String.self, forKey: .graphqlOperation)
    }
}
