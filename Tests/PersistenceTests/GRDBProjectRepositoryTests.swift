import Testing
import Foundation
@testable import Persistence
import Domain

@Suite("GRDBProjectRepository")
struct GRDBProjectRepositoryTests {

    private func makeRepo() throws -> GRDBProjectRepository {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        return GRDBProjectRepository(dbQueue: dbQueue)
    }

    // MARK: - Basic Save and Load

    @Test func saveAndLoadProject() async throws {
        let repo = try makeRepo()
        let config = ServerConfiguration(port: 9090, globalDelayMs: 50)
        let project = MockProject(name: "API Mock", serverConfiguration: config)

        try await repo.save(project)
        let loaded = try await repo.load(id: project.id)

        #expect(loaded.id == project.id)
        #expect(loaded.name == "API Mock")
        #expect(loaded.serverConfiguration.port == 9090)
        #expect(loaded.serverConfiguration.globalDelayMs == 50)
    }

    // MARK: - Nested Endpoints and Scenarios

    @Test func saveAndLoadWithEndpointsAndScenarios() async throws {
        let repo = try makeRepo()
        let scenario1 = Scenario(name: "Success", statusCode: 200, headers: ["Content-Type": "application/json"], body: "{\"id\":1}", bodyContentType: .json)
        let endpoint1 = Endpoint(name: "Get User", method: .get, path: "/api/user", scenarios: [scenario1], activeScenarioID: scenario1.id)

        let scenario2 = Scenario(name: "Created", statusCode: 201, body: "{\"created\":true}", bodyContentType: .json)
        let endpoint2 = Endpoint(name: "Create User", method: .post, path: "/api/user", scenarios: [scenario2])

        let project = MockProject(name: "User API", endpoints: [endpoint1, endpoint2])

        try await repo.save(project)
        let loaded = try await repo.load(id: project.id)

        #expect(loaded.endpoints.count == 2)
        #expect(loaded.endpoints[0].scenarios.count == 1)
        #expect(loaded.endpoints[1].scenarios.count == 1)
        #expect(loaded.endpoints[0].name == "Get User")
        #expect(loaded.endpoints[0].scenarios[0].statusCode == 200)
        #expect(loaded.endpoints[1].name == "Create User")
        #expect(loaded.endpoints[1].scenarios[0].statusCode == 201)
    }

    // MARK: - allProjects

    @Test func allProjectsReturnsLightweightStubs() async throws {
        let repo = try makeRepo()
        let now = Date()
        let project1 = MockProject(name: "Alpha", createdAt: now.addingTimeInterval(-200), modifiedAt: now.addingTimeInterval(-200))
        let project2 = MockProject(name: "Beta", createdAt: now.addingTimeInterval(-100), modifiedAt: now.addingTimeInterval(-100))
        let project3 = MockProject(name: "Gamma", createdAt: now, modifiedAt: now)

        try await repo.save(project1)
        try await repo.save(project2)
        try await repo.save(project3)

        let all = try await repo.allProjects()

        #expect(all.count == 3)
        #expect(all[0].name == "Gamma")
        #expect(all[1].name == "Beta")
        #expect(all[2].name == "Alpha")
        // Lightweight stubs — no endpoints loaded
        #expect(all[0].endpoints.isEmpty)
        #expect(all[1].endpoints.isEmpty)
        #expect(all[2].endpoints.isEmpty)
    }

    @Test func allProjectsReturnsStubsEvenWhenEndpointsExist() async throws {
        let repo = try makeRepo()
        let endpoint = Endpoint(name: "Health", method: .get, path: "/health")
        let project = MockProject(name: "WithEndpoints", endpoints: [endpoint])

        try await repo.save(project)
        let all = try await repo.allProjects()

        #expect(all.count == 1)
        #expect(all[0].endpoints.isEmpty)
    }

    // MARK: - Delete with cascade

    @Test func deleteProjectCascades() async throws {
        let repo = try makeRepo()
        let scenario = Scenario(name: "OK", statusCode: 200)
        let endpoint = Endpoint(name: "Health", method: .get, path: "/health", scenarios: [scenario])
        let project = MockProject(name: "App", endpoints: [endpoint])

        try await repo.save(project)
        try await repo.delete(id: project.id)

        await #expect(throws: PersistenceError.self) {
            _ = try await repo.load(id: project.id)
        }
    }

    // MARK: - Load nonexistent

    @Test func loadNonexistentProjectThrows() async {
        let repo = try! makeRepo()
        let randomID = UUID()

        await #expect(throws: PersistenceError.self) {
            _ = try await repo.load(id: randomID)
        }
    }

    // MARK: - Update (re-save)

    @Test func saveUpdatesExistingProject() async throws {
        let repo = try makeRepo()
        var project = MockProject(name: "Original")
        try await repo.save(project)

        project.name = "Updated"
        try await repo.save(project)

        let loaded = try await repo.load(id: project.id)
        #expect(loaded.name == "Updated")
    }

    // MARK: - Duplicate project

    /// This test used to duplicate `MockProject(name: "My Project")` — a project with no endpoints and
    /// no journeys — and pass. Nothing else duplicated a project with anything in it, so a feature
    /// that could not work on any real project shipped with two green tests over it.
    ///
    /// `endpoint.id`, `scenario.id`, `journey.id` and `journeyStep.id` are primary keys across the
    /// whole database, not scoped to a project, and `save` deletes children by the incoming project's
    /// id — which matches nothing for a project that does not exist yet — before inserting. So a copy
    /// carrying the source's child ids collided with the original on the first insert, GRDB aborted,
    /// and the entire write rolled back. The fixture is what hid it: with no children there is nothing
    /// to collide.
    @Test("Duplicating a project with content stores both, sharing no identifier")
    func duplicateProjectWithContent() async throws {
        let repo = try makeRepo()

        let ok = Scenario(name: "OK", statusCode: 200, body: "{}")
        let unauthorized = Scenario(name: "Unauthorized", statusCode: 401)
        let endpoint = Endpoint(
            name: "Account",
            method: .get,
            path: "/account",
            scenarios: [ok, unauthorized],
            // The *second* scenario is active, so following it by position is actually exercised.
            activeScenarioID: unauthorized.id,
            groupTag: "Billing"
        )
        let journey = Journey(
            name: "Retry",
            steps: [
                JourneyStep(name: "fails", method: .get, path: "/account",
                            outcome: .respond(JourneyResponse(statusCode: 500))),
                JourneyStep(name: "succeeds", method: .get, path: "/account",
                            outcome: .respond(JourneyResponse(statusCode: 200))),
            ]
        )
        let original = MockProject(
            name: "My Project",
            endpoints: [endpoint],
            journeys: [journey],
            activeJourneyID: journey.id
        )
        try await repo.save(original)

        let copy = original.duplicated(name: "\(original.name) (Copy)")
        try await repo.save(copy)

        // Both survive. Before the fix, this `load` threw: the copy's write rolled back entirely.
        let loadedOriginal = try await repo.load(id: original.id)
        let loadedCopy = try await repo.load(id: copy.id)

        #expect(loadedCopy.name == "My Project (Copy)")
        #expect(loadedOriginal.id != loadedCopy.id)

        // Content is carried over.
        #expect(loadedCopy.endpoints.count == 1)
        #expect(loadedCopy.endpoints.first?.path == "/account")
        #expect(loadedCopy.endpoints.first?.scenarios.count == 2)
        #expect(loadedCopy.endpoints.first?.groupTag == "Billing")
        #expect(loadedCopy.journeys.count == 1)
        #expect(loadedCopy.journeys.first?.steps.count == 2)

        // Identity is not. Every id in the copy is new, at every level of the tree — otherwise an
        // edit to the copy reaches into the original's rows.
        let originalIDs = Self.identifiers(of: loadedOriginal)
        let copyIDs = Self.identifiers(of: loadedCopy)
        #expect(originalIDs.isDisjoint(with: copyIDs), "shared ids: \(originalIDs.intersection(copyIDs))")

        // The two references that point *into* the tree follow the copy, not the original.
        let copiedEndpoint = try #require(loadedCopy.endpoints.first)
        #expect(copiedEndpoint.activeScenarioID == copiedEndpoint.scenarios[1].id)
        #expect(copiedEndpoint.scenarios[1].name == "Unauthorized")
        #expect(loadedCopy.activeJourneyID == loadedCopy.journeys.first?.id)
        #expect(loadedCopy.activeJourney?.name == "Retry")

        // And the original is untouched by any of it.
        #expect(loadedOriginal.endpoints.first?.activeScenarioID == unauthorized.id)
        #expect(loadedOriginal.activeJourneyID == journey.id)
    }

    /// Every identifier in a project, at every level — the set a copy must not intersect.
    private static func identifiers(of project: MockProject) -> Set<UUID> {
        var ids: Set<UUID> = [project.id]
        for endpoint in project.endpoints {
            ids.insert(endpoint.id)
            ids.formUnion(endpoint.scenarios.map(\.id))
        }
        for journey in project.journeys {
            ids.insert(journey.id)
            ids.formUnion(journey.steps.map(\.id))
        }
        return ids
    }

    // MARK: - Sort order

    @Test func endpointSortOrderPreserved() async throws {
        let repo = try makeRepo()
        let endpoint1 = Endpoint(name: "First", method: .get, path: "/first")
        let endpoint2 = Endpoint(name: "Second", method: .get, path: "/second")
        let endpoint3 = Endpoint(name: "Third", method: .get, path: "/third")
        let project = MockProject(name: "Ordered", endpoints: [endpoint1, endpoint2, endpoint3])

        try await repo.save(project)
        let loaded = try await repo.load(id: project.id)

        #expect(loaded.endpoints.count == 3)
        #expect(loaded.endpoints[0].name == "First")
        #expect(loaded.endpoints[1].name == "Second")
        #expect(loaded.endpoints[2].name == "Third")
    }
}
