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

    /// The same poll for a predicate that has to ask the store, which is asynchronous. Named apart
    /// from `waitUntil` rather than overloaded on the closure's effects: two overloads differing only
    /// in `async` is exactly the shape that resolves to whichever one the compiler happens to prefer.
    private func waitUntilAsync(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(20),
        _ predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() {
                return
            }
            try await Task.sleep(for: interval)
        }
        Issue.record("Timed out waiting for condition")
    }

    /// A store that refuses every write and holds nothing.
    ///
    /// Stateless, so it needs no `@unchecked`: `ProjectRepository` is `Sendable` and a struct with no
    /// stored properties satisfies that on its own.
    ///
    /// `nonisolated` because `MimicTests` compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
    /// so an unannotated type here is `@MainActor` — and `ProjectRepository` is a nonisolated protocol
    /// declared in `Domain`, whose conformances the app's real repositories satisfy off the main
    /// actor. Same reason `NavigationHistory` carries it in `AppFeatures`.
    private nonisolated struct RefusingRepository: ProjectRepository {
        struct Refused: Error, LocalizedError {
            var errorDescription: String? { "the store refused the write" }
        }

        func load(id: UUID) async throws -> MockProject { throw PersistenceError.projectNotFound(id) }
        func save(_ project: MockProject) async throws { throw Refused() }
        func allProjects() async throws -> [MockProject] { [] }
        func delete(id: UUID) async throws { throw Refused() }
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

    // MARK: - The debounce and the project moving out from under it

    /// The failure this app had no way of telling you about.
    ///
    /// `scheduleAutosave` waits 500 ms and then re-reads `currentProject`, guarding that it is still
    /// the project the edit belonged to. Closing clears that property, so the pending task woke up,
    /// found the guard false, and returned having written nothing — no error, no indicator, and an
    /// edit that simply was not there when you reopened the project.
    ///
    /// The close deliberately happens *inside* the debounce window, because outside it there is
    /// nothing to lose.
    @Test("Closing a project writes the edit still sitting in the debounce")
    func closingFlushesThePendingAutosave() async throws {
        let context = try makeContext()
        let service = context.service

        _ = service.createProject(name: "Flushed", port: 8080)
        try await waitUntil { service.recentProjects.count == 1 }
        let id = try #require(service.currentProject?.id)

        service.currentProject?.name = "Edited inside the debounce"
        service.scheduleAutosave()
        service.closeProject()

        #expect(service.currentProject == nil)
        try await waitUntilAsync {
            (try? await context.repository.load(id: id))?.name == "Edited inside the debounce"
        }
    }

    /// The same loss from the other direction: opening another project replaces `currentProject`, so
    /// the pending write for the *outgoing* one found a different project under the guard and gave up.
    ///
    /// The flush captures the project by value before the property moves, which is what makes the
    /// write independent of whatever is open by the time it lands.
    @Test("Switching projects writes the outgoing project's pending edit")
    func switchingProjectsFlushesThePendingAutosave() async throws {
        let context = try makeContext()
        let service = context.service

        _ = service.createProject(name: "First", port: 8080)
        try await waitUntil { service.recentProjects.count == 1 }
        let firstID = try #require(service.currentProject?.id)

        _ = service.createProject(name: "Second", port: 8081)
        try await waitUntil { service.recentProjects.count == 2 }
        let secondID = try #require(service.currentProject?.id)

        service.openProject(id: firstID)
        try await waitUntil { service.currentProject?.id == firstID }

        service.currentProject?.name = "Edited before switching away"
        service.scheduleAutosave()
        service.openProject(id: secondID)

        try await waitUntil { service.currentProject?.id == secondID }
        try await waitUntilAsync {
            (try? await context.repository.load(id: firstID))?.name == "Edited before switching away"
        }
    }

    // The third member of this family — `deleteProject` cancelling the pending write so a debounced
    // save cannot put the row back — is deliberately **not** tested here, because no test in this
    // file could fail for that reason. The debounced task guards on `currentProject`, and the delete
    // clears it, so the row is only resurrected when the save wakes in the narrow window between
    // `deleteProject(id:)` being called and its own task nilling the property. A test that drove that
    // would pass whether or not the cancellation exists, which is the shape this whole pass is here
    // to remove. The cancellation is still right — it makes the outcome independent of the race
    // rather than merely unlikely — it is just not something an assertion here can see.

    // MARK: - Importing a document

    /// `AppControlHost` used to store an imported document itself, as
    /// `Task { try? await repository.save(document) }` beside a success envelope — so
    /// `mimic project import` exited 0 on an import that never happened and the window said nothing.
    @Test("A refused import reports the failure instead of reporting success")
    func importReportsARefusedWrite() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ProjectWorkspaceTests.\(UUID().uuidString)"))
        let service = ProjectWorkspace(
            projectRepository: RefusingRepository(),
            recentProjectsStore: RecentProjectsStore(defaults: defaults)
        )

        let stored = await service.importProject(MockProject(name: "Refused"))

        #expect(stored == false)
        #expect(service.autosaveStatus == .failed("Could not import project \"Refused\"."))
        #expect(service.recentProjects.contains { $0.name == "Refused" } == false)
    }

    @Test("An accepted import is in the store and in the list")
    func importStoresTheDocument() async throws {
        let context = try makeContext()
        let scenario = Scenario(name: "Default", statusCode: 200, body: "{}")
        let document = MockProject(
            name: "Imported",
            endpoints: [
                Endpoint(
                    name: "Summary",
                    method: .get,
                    path: "/account-summary",
                    scenarios: [scenario],
                    activeScenarioID: scenario.id
                ),
            ]
        )

        let stored = await context.service.importProject(document)

        #expect(stored)
        let loaded = try await context.repository.load(id: document.id)
        #expect(loaded.name == "Imported")
        #expect(loaded.endpoints.first?.path == "/account-summary")
        try await waitUntil { context.service.recentProjects.contains { $0.id == document.id } }
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
