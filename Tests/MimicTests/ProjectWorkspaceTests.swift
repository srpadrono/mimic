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

        // Saved through the repository directly so the *source* row exists for the read-back
        // assertions below. The duplicate itself does not need the store to be current any more:
        // the source is the open project, and `duplicateProject` copies the session for that case —
        // `duplicatingTheOpenProjectCarriesThePendingEdit` below is the test that pins it.
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

    /// Manifestation (b) of the write-ordering class: `duplicateProject` loaded its source from the
    /// store, and the store is up to half a second behind the session — the debounce window. So
    /// `mimic project duplicate` of the open project silently omitted the caller's newest edits and
    /// exited 0. The source is the session copy now whenever the reference names the open project —
    /// the same "session wins" rule `AppControlHost.projectExport` applies, and for the same reason.
    @Test("Duplicating the open project carries the edit still sitting in the debounce")
    func duplicatingTheOpenProjectCarriesThePendingEdit() async throws {
        let context = try makeContext()
        let service = context.service

        _ = service.createProject(name: "Source", port: 8080)
        try await waitUntil { service.recentProjects.count == 1 }
        let id = try #require(service.currentProject?.id)

        // An endpoint added and *not yet stored*: the debounce has not fired when the duplicate is
        // asked for, which is exactly the window the store-read implementation lost.
        _ = service.mutateCurrentProject { project in
            let scenario = Scenario(name: "OK", statusCode: 200, body: "{}")
            project.endpoints.append(
                Endpoint(name: "Added inside the debounce", method: .get, path: "/debounced",
                         scenarios: [scenario], activeScenarioID: scenario.id)
            )
        }
        service.scheduleAutosave()
        service.duplicateProject(id: id)

        try await waitUntil { service.recentProjects.contains { $0.name == "Source (Copy)" } }
        let copyID = try #require(service.recentProjects.first(where: { $0.name == "Source (Copy)" })?.id)
        let copy = try await context.repository.load(id: copyID)
        #expect(
            copy.endpoints.map(\.path) == ["/debounced"],
            "the duplicate was taken from the store, which is missing the debounce-window edit"
        )
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

    // MARK: - The write chain: nothing overtakes, nothing resurrects
    //
    // Every store write joins `ProjectWorkspace.storeWrites` — see that property's documentation.
    // Before the discipline closed over them, five write paths sat outside the chain (the debounced
    // autosave, the flush, the explicit save, plus two callers' compositions of them), and each one
    // racing a chained lifecycle write could reorder the store. The tests below drive each seam
    // against `GatedRepository`, whose first save stays open until a delete overtakes it or a
    // deadline passes — so an inversion is *forced* to happen if the code allows it, rather than
    // left to scheduler luck.

    /// A store that holds its first save open until a delete overtakes it, and records the order
    /// writes actually arrive in. The same shape as the fixture in `AppStateAndViewTests` — a test
    /// target is one module, but the two suites keep their own fixtures private.
    ///
    /// The gate is what makes the assertions claims rather than coincidences: a `save` that simply
    /// returned would let a delete issued moments later land after it by luck on a quick machine,
    /// and a test would pass against the very inversion it exists to catch. This save cannot return
    /// until the delete has had its chance — with a deadline, because in a correctly ordered run
    /// the delete never arrives until the save is done.
    private actor GatedRepository: ProjectRepository {
        private(set) var operations: [String] = []
        private var projects: [UUID: MockProject] = [:]
        private var hasGatedASave = false

        var didBeginSaving: Bool { operations.contains("save.begin") }
        func stored(_ id: UUID) -> MockProject? { projects[id] }
        func seed(_ project: MockProject) { projects[project.id] = project }

        func save(_ project: MockProject) async throws {
            operations.append("save.begin")
            if !hasGatedASave {
                hasGatedASave = true
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while ContinuousClock.now < deadline, !operations.contains("delete") {
                    // Every hop releases the actor, which is what lets a delete that is not
                    // waiting its turn reach `delete(id:)` while this write is still open.
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            projects[project.id] = project
            operations.append("save.end")
        }

        func load(id: UUID) async throws -> MockProject {
            guard let project = projects[id] else { throw PersistenceError.projectNotFound(id) }
            return project
        }

        func allProjects() async throws -> [MockProject] { Array(projects.values) }

        func delete(id: UUID) async throws {
            operations.append("delete")
            projects[id] = nil
        }
    }

    /// A workspace over ``GatedRepository`` holding one seeded, open project — the fixture the three
    /// overtake tests share. Seeded by direct assignment rather than `createProject`, so the gated
    /// first save is the save under test and not the create's.
    private func makeGatedContext(
        projectName: String
    ) async throws -> (service: ProjectWorkspace, repository: GatedRepository, project: MockProject) {
        let repository = GatedRepository()
        let defaults = try #require(UserDefaults(suiteName: "ProjectWorkspaceTests.\(UUID().uuidString)"))
        let service = ProjectWorkspace(
            projectRepository: repository,
            recentProjectsStore: RecentProjectsStore(defaults: defaults)
        )
        let project = MockProject(name: projectName)
        await repository.seed(project)
        service.currentProject = project
        return (service, repository, project)
    }

    /// Manifestation (d) of the write-ordering class: `closeProject`'s flush used to dispatch a
    /// free-floating save, so a `mimic project delete` chained right behind the close could reach
    /// the store first — deleting the row — and the flush's save then landed after it and put the
    /// row back. The flush joins the chain now, so the delete cannot start until it has settled.
    @Test("A delete chained behind a close cannot overtake the flushed edit")
    func closeFlushCannotBeOvertakenByAChainedDelete() async throws {
        let (service, repository, seeded) = try await makeGatedContext(projectName: "Closing")

        var edited = seeded
        edited.name = "Edited before closing"
        service.currentProject = edited
        service.scheduleAutosave()
        service.closeProject()
        service.deleteProject(id: seeded.id)

        try await waitUntilAsync(timeout: .seconds(5)) { await repository.operations.count == 3 }

        #expect(await repository.operations == ["save.begin", "save.end", "delete"])
        #expect(
            await repository.stored(seeded.id) == nil,
            "the delete removed nothing and the flushed save put the row back behind it"
        )
    }

    /// Manifestation (a), explicit-save seam: `saveCurrentProject` used to dispatch a free-floating
    /// task, so the same delete-overtakes-save inversion was open on the File ▸ Save path.
    @Test("A delete issued after an explicit save still reaches the store after it")
    func explicitSaveCannotBeOvertakenByAChainedDelete() async throws {
        let (service, repository, seeded) = try await makeGatedContext(projectName: "Saved")

        service.saveCurrentProject()
        service.deleteProject(id: seeded.id)

        try await waitUntilAsync(timeout: .seconds(5)) { await repository.operations.count == 3 }

        #expect(await repository.operations == ["save.begin", "save.end", "delete"])
        #expect(
            await repository.stored(seeded.id) == nil,
            "the delete removed nothing and the explicit save put the row back behind it"
        )
    }

    /// Manifestation (a), debounce seam: once the 500 ms debounce fired, the write it claimed was a
    /// free-floating task, and a delete arriving while that save was in flight could land inside it
    /// and be overwritten. The claimed write joins the chain now, so the delete waits its turn.
    ///
    /// The delete is issued only once the save has genuinely begun — after the claim, which is the
    /// window `deleteProject`'s own cancellation cannot cover.
    @Test("A debounced write already in flight cannot be overtaken by a chained delete")
    func claimedAutosaveCannotBeOvertakenByAChainedDelete() async throws {
        let (service, repository, seeded) = try await makeGatedContext(projectName: "Debounced")

        service.scheduleAutosave()
        try await waitUntilAsync { await repository.didBeginSaving }
        service.deleteProject(id: seeded.id)

        try await waitUntilAsync(timeout: .seconds(5)) { await repository.operations.count == 3 }

        #expect(await repository.operations == ["save.begin", "save.end", "delete"])
        #expect(
            await repository.stored(seeded.id) == nil,
            "the delete removed nothing and the debounced save put the row back behind it"
        )
    }

    /// A store whose delete stays open past the 500 ms debounce, so a pending autosave that was
    /// *not* cancelled fires mid-delete and — writes being chained — lands right behind it,
    /// resurrecting the row deterministically.
    ///
    /// This family's third member used to be documented as untestable: with free-floating saves the
    /// resurrection needed the debounce to wake inside a narrow scheduling window, so a test passed
    /// whether or not the cancellation existed. The chain changed that — an uncancelled debounce
    /// now *always* enqueues behind the delete it should have died with — so the cancellation in
    /// `deleteProject` finally has a test that fails without it.
    private actor SlowDeleteRepository: ProjectRepository {
        private(set) var operations: [String] = []
        private var projects: [UUID: MockProject] = [:]

        func stored(_ id: UUID) -> MockProject? { projects[id] }
        func seed(_ project: MockProject) { projects[project.id] = project }

        func save(_ project: MockProject) async throws {
            projects[project.id] = project
            operations.append("save")
        }

        func load(id: UUID) async throws -> MockProject {
            guard let project = projects[id] else { throw PersistenceError.projectNotFound(id) }
            return project
        }

        func allProjects() async throws -> [MockProject] { Array(projects.values) }

        func delete(id: UUID) async throws {
            operations.append("delete.begin")
            // Longer than the debounce, so an uncancelled autosave fires while this holds the chain.
            try? await Task.sleep(for: .milliseconds(700))
            projects[id] = nil
            operations.append("delete.end")
        }
    }

    @Test("Deleting the open project drops the debounced edit instead of resurrecting the row")
    func deletingTheOpenProjectCancelsThePendingAutosave() async throws {
        let repository = SlowDeleteRepository()
        let defaults = try #require(UserDefaults(suiteName: "ProjectWorkspaceTests.\(UUID().uuidString)"))
        let service = ProjectWorkspace(
            projectRepository: repository,
            recentProjectsStore: RecentProjectsStore(defaults: defaults)
        )
        let project = MockProject(name: "Doomed")
        await repository.seed(project)
        service.currentProject = project

        service.scheduleAutosave()
        service.deleteProject(id: project.id)

        try await waitUntilAsync(timeout: .seconds(5)) { await repository.operations.contains("delete.end") }
        // Room for a wrongly surviving autosave — enqueued behind the delete — to land and be seen.
        try await Task.sleep(for: .milliseconds(200))

        #expect(service.currentProject == nil)
        #expect(await repository.operations.contains("save") == false,
                "the pending autosave outlived the delete of its own project")
        #expect(await repository.stored(project.id) == nil,
                "the debounced save re-inserted the row the delete had just removed")
    }

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
