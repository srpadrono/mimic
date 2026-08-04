import Testing
import Persistence
import Domain
import GRDB
import Foundation

/// Tests that verify the autosave debounce contract — 500 ms quiet period before write,
/// coalescing of rapid mutations, and no spurious save on project restore.
@Suite("Autosave Debounce", .serialized)
struct AutosaveDebounceTests {

    /// A minimal autosave scheduler that mirrors AppState.scheduleAutosave() logic.
    @MainActor
    final class DebounceScheduler {
        let repo: GRDBProjectRepository
        var currentProject: MockProject?
        var saveCount = 0
        private var autosaveTask: Task<Void, Never>?
        var isRestoring = false

        init(repo: GRDBProjectRepository) {
            self.repo = repo
        }

        func scheduleAutosave() {
            guard !isRestoring, currentProject != nil else { return }
            autosaveTask?.cancel()
            autosaveTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    guard let self, let project = self.currentProject else { return }
                    try await self.repo.save(project)
                    self.saveCount += 1
                } catch is CancellationError {
                    // Superseded by newer change
                } catch {
                    // Ignore other errors in tests
                }
            }
        }

        func restoreProject(_ project: MockProject) {
            isRestoring = true
            currentProject = project
            isRestoring = false
        }
    }

    @MainActor
    private func makeScheduler() throws -> (DebounceScheduler, GRDBProjectRepository) {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repo = GRDBProjectRepository(dbQueue: dbQueue)
        let scheduler = DebounceScheduler(repo: repo)
        return (scheduler, repo)
    }

    // MARK: - Tests

    @Test @MainActor func autosaveFiresAfterDebounce() async throws {
        let (scheduler, repo) = try makeScheduler()
        let project = MockProject(name: "Test", serverConfiguration: .default)
        scheduler.currentProject = project
        try await repo.save(project)

        let mutated = MockProject(id: project.id, name: "Modified", serverConfiguration: project.serverConfiguration, endpoints: project.endpoints, createdAt: project.createdAt)
        scheduler.currentProject = mutated
        scheduler.scheduleAutosave()

        try await Task.sleep(for: .milliseconds(700))

        let loaded = try await repo.load(id: project.id)
        #expect(loaded.name == "Modified")
        #expect(scheduler.saveCount == 1)
    }

    @Test @MainActor func rapidMutationsProduceOneSave() async throws {
        let (scheduler, repo) = try makeScheduler()
        let project = MockProject(name: "Rapid", serverConfiguration: .default)
        try await repo.save(project)
        scheduler.currentProject = project

        for i in 1...5 {
            let updated = MockProject(id: project.id, name: "Mutation \(i)", serverConfiguration: project.serverConfiguration, endpoints: project.endpoints, createdAt: project.createdAt)
            scheduler.currentProject = updated
            scheduler.scheduleAutosave()
            try await Task.sleep(for: .milliseconds(50))
        }

        try await Task.sleep(for: .milliseconds(700))

        #expect(scheduler.saveCount == 1)
        let loaded = try await repo.load(id: project.id)
        #expect(loaded.name == "Mutation 5")
    }

    @Test @MainActor func restoringProjectDoesNotTriggerAutosave() async throws {
        let (scheduler, repo) = try makeScheduler()
        let project = MockProject(name: "Original", serverConfiguration: .default)
        try await repo.save(project)

        scheduler.restoreProject(project)

        try await Task.sleep(for: .milliseconds(700))

        #expect(scheduler.saveCount == 0)
        let loaded = try await repo.load(id: project.id)
        #expect(loaded.name == "Original")
    }
}
