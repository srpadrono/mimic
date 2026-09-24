import Domain
import Foundation
import Persistence
import Testing
@testable import AppFeatures

@Suite("App control host project listing")
@MainActor
struct AppControlHostCountFailureTests {
    private nonisolated struct CountFailingRepository: ProjectRepository {
        let project: MockProject

        func load(id: UUID) async throws -> MockProject { project }
        func save(_ project: MockProject) async throws {}
        func allProjects() async throws -> [MockProject] { [project] }
        func delete(id: UUID) async throws {}

        func projectCounts() async throws -> [UUID: ProjectCounts] {
            throw PersistenceError.unsupportedSchemaVersion(
                name: project.name, stored: 2, supported: 1
            )
        }
    }

    @Test("A failed count query fails the listing instead of reporting zero counts")
    func countFailureFailsProjectList() async throws {
        let project = MockProject(name: "Stored API")
        let repository = CountFailingRepository(project: project)
        let defaults = try #require(UserDefaults(suiteName: "CountFailure.\(UUID().uuidString)"))
        let appState = AppState(
            projectRepository: repository,
            recentProjectsStore: RecentProjectsStore(defaults: defaults),
            panelLayoutStore: PanelLayoutStore(defaults: defaults),
            updates: UpdateService(
                installedVersion: { ReleaseVersion(major: 1, minor: 0, patch: 0) },
                preferences: UpdatePreferences(defaults: defaults)
            )
        )
        let host = AppControlHost(appState: appState, repository: repository)

        let response = await host.execute(.projectList)

        #expect(response.ok == false)
        #expect(response.result?.projects == nil)
        #expect(response.error?.code == "persistence.failure")
        #expect(response.error?.message.contains("Stored API") == true)
    }
}
