import Foundation
import Testing
import Persistence
import Domain
@testable import AppFeatures

@Suite("ProjectWorkspace Tests")
@MainActor
struct ProjectWorkspaceTests {
    private struct Context {
        let service: ProjectWorkspace
        let repository: GRDBProjectRepository
        let store: RecentProjectsStore
        let defaults: UserDefaults
    }

    private func makeContext() throws -> Context {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)
        let defaults = UserDefaults(suiteName: "ProjectWorkspaceTests.\(UUID().uuidString)")!
        let store = RecentProjectsStore(defaults: defaults)
        let service = ProjectWorkspace(projectRepository: repository, recentProjectsStore: store)
        return Context(service: service, repository: repository, store: store, defaults: defaults)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(20),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(for: interval)
        }
        Issue.record("Timed out waiting for condition")
    }

    @Test("Project creation persists recents and updates autosave state")
    func projectCreation() async throws {
        let context = try makeContext()
        let service = context.service

        let config = service.createProject(name: "Test API", port: 9000)
        #expect(config.port == 9000)
        #expect(service.currentProject?.name == "Test API")
        #expect(service.isRestoringProject == false)

        try await waitUntil {
            service.recentProjects.first?.name == "Test API" && service.autosaveStatus == .saved
        }

        #expect(service.recentProjects.count == 1)
        #expect(context.store.lastOpenedProjectID() == service.currentProject?.id)
    }

    @Test("Open project loads persisted projects and missing projects clear recents")
    func openProjectHandlesSuccessAndMissingIDs() async throws {
        let context = try makeContext()
        let service = context.service

        _ = service.createProject(name: "Users API", port: 8080)
        try await waitUntil {
            service.currentProject != nil && service.recentProjects.count == 1
        }

        let existingID = try #require(service.currentProject?.id)
        service.closeProject()
        service.openProject(id: existingID)
        try await waitUntil {
            service.currentProject?.id == existingID
        }

        let missingID = UUID()
        context.store.record(id: missingID, name: "Missing")
        service.recentProjects = context.store.load()
        service.openProject(id: missingID)
        try await waitUntil {
            service.recentProjects.contains(where: { $0.id == missingID }) == false
        }
    }

    @Test("Save current project no-ops without a project and autosave persists changes")
    func saveAndAutosave() async throws {
        let context = try makeContext()
        let service = context.service

        service.saveCurrentProject()
        #expect(service.autosaveStatus == .idle)

        _ = service.createProject(name: "Autosave API")
        try await waitUntil {
            service.currentProject != nil
        }

        service.currentProject?.name = "Autosave API Updated"
        service.scheduleAutosave()

        try await waitUntil {
            service.recentProjects.first?.name == "Autosave API Updated"
                && (service.autosaveStatus == .saved || service.autosaveStatus == .idle)
        }

        #expect(service.recentProjects.first?.name == "Autosave API Updated")
    }

    @Test("Autosave respects restoration and missing project guards")
    func autosaveGuards() async throws {
        let context = try makeContext()
        let service = context.service

        service.scheduleAutosave()
        #expect(service.autosaveStatus == .idle)

        _ = service.createProject(name: "Restoring API")
        try await waitUntil {
            service.currentProject != nil && service.recentProjects.first?.name == "Restoring API"
        }

        service.isRestoringProject = true
        service.currentProject?.name = "Ignored Rename"
        service.scheduleAutosave()
        try await Task.sleep(for: .milliseconds(600))

        #expect(service.recentProjects.first?.name == "Restoring API")
        service.isRestoringProject = false
    }

    @Test("Duplicate delete and close project cover missing and existing IDs")
    func duplicateDeleteAndClose() async throws {
        let context = try makeContext()
        let service = context.service

        _ = service.createProject(name: "Source API")
        try await waitUntil {
            service.currentProject != nil && service.recentProjects.count == 1
        }

        // The source has content. This test used to duplicate an empty project, which is the only
        // shape the old implementation could copy: it carried the source's endpoint and scenario ids
        // into the copy, and those are primary keys across the whole database, so the insert collided
        // and the write rolled back. With nothing to collide, the bug was invisible here.
        _ = service.mutateCurrentProject { project in
            let scenario = Scenario(name: "OK", statusCode: 200, body: "{}")
            project.endpoints.append(
                Endpoint(name: "Account", method: .get, path: "/account",
                         scenarios: [scenario], activeScenarioID: scenario.id)
            )
        }

        // Saved through the repository directly rather than by polling an autosave: `duplicateProject`
        // reads the source back out of the store, so the store has to be current before it runs, and
        // a deterministic await beats waiting on a debounce.
        let source = try #require(service.currentProject)
        try await context.repository.save(source)
        let sourceID = source.id

        service.duplicateProject(id: sourceID)
        service.duplicateProject(id: UUID())

        try await waitUntil {
            service.recentProjects.count >= 2
        }

        #expect(service.recentProjects.contains(where: { $0.name == "Source API (Copy)" }))

        // The recents entry is a `UserDefaults` write and happens whether or not the store accepted
        // anything — which is why it alone could not catch this. Load the copy back.
        let copyID = try #require(service.recentProjects.first(where: { $0.name == "Source API (Copy)" })?.id)
        let storedCopy = try await context.repository.load(id: copyID)
        #expect(storedCopy.endpoints.count == 1, "the duplicate persisted no endpoints")
        #expect(storedCopy.endpoints.first?.path == "/account")
        let storedSource = try await context.repository.load(id: sourceID)
        #expect(storedSource.endpoints.first?.id != storedCopy.endpoints.first?.id)

        service.deleteProject(id: sourceID)
        try await waitUntil {
            service.currentProject == nil
        }

        #expect(service.recentProjects.contains(where: { $0.id == sourceID }) == false)

        service.closeProject()
        #expect(service.currentProject == nil)
        _ = context
    }

    @Test("Load last opened project restores persisted state and clears stale IDs")
    func loadLastOpenedProject() async throws {
        let context = try makeContext()
        let service = context.service

        #expect(service.loadLastOpenedProject() == nil)

        _ = service.createProject(name: "Recovered API", port: 8181)
        try await waitUntil {
            service.currentProject != nil && service.recentProjects.count == 1
        }

        let storedID = try #require(service.currentProject?.id)
        let restored = ProjectWorkspace(
            projectRepository: context.repository,
            recentProjectsStore: context.store
        )

        #expect(restored.loadLastOpenedProject() == nil)
        try await waitUntil {
            restored.currentProject?.id == storedID
        }

        let staleID = UUID()
        context.store.record(id: staleID, name: "Stale")
        let staleService = ProjectWorkspace(
            projectRepository: context.repository,
            recentProjectsStore: context.store
        )
        #expect(staleService.loadLastOpenedProject() == nil)
        try await waitUntil {
            staleService.recentProjects.contains(where: { $0.id == staleID }) == false
        }
    }
}
