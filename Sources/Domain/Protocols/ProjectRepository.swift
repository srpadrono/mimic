import Foundation

/// How many endpoints and journeys a project holds, without loading it.
public struct ProjectCounts: Sendable, Equatable {
    public var endpoints: Int
    public var journeys: Int

    public init(endpoints: Int, journeys: Int) {
        self.endpoints = endpoints
        self.journeys = journeys
    }
}

public protocol ProjectRepository: Sendable {
    func load(id: UUID) async throws -> MockProject
    func save(_ project: MockProject) async throws
    /// Lightweight stubs — endpoints and journeys are not populated.
    func allProjects() async throws -> [MockProject]
    func delete(id: UUID) async throws

    /// Counts for a listing. A store that can count in its query language should implement this;
    /// the default loads each project, which is correct but not cheap.
    func projectCounts() async throws -> [UUID: ProjectCounts]
}

extension ProjectRepository {
    /// Correct-but-slow fallback so conformances are not forced to implement counting. `mimic project
    /// list` stays accurate against any store, and fast against one that overrides this.
    public func projectCounts() async throws -> [UUID: ProjectCounts] {
        var counts: [UUID: ProjectCounts] = [:]
        for stub in try await allProjects() {
            let project = try await load(id: stub.id)
            counts[project.id] = ProjectCounts(
                endpoints: project.endpoints.count,
                journeys: project.journeys.count
            )
        }
        return counts
    }
}
