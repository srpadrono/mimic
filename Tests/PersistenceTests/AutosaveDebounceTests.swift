import Testing
import Persistence
import Domain
import GRDB
import Foundation

/// What a 500 ms debounce asks of the **store**, driven through a model of the scheduler rather than
/// through the scheduler itself.
///
/// ## Why a model, and what it is a model of
///
/// The production scheduler is `ProjectWorkspace.scheduleAutosave()`, which lives in `AppFeatures`.
/// This is `PersistenceTests`, and a test target is a module: it links `Persistence`, `Domain` and
/// `GRDB`, and cannot import `AppFeatures` at all. So this file cannot drive the real type, and
/// nothing here should be read as covering it.
///
/// What it *does* cover is the half that is Persistence's: that a `GRDBProjectRepository` under a
/// debounce takes one write for a burst of edits, that the row that lands is the last mutation rather
/// than an intermediate one, and that a restore writes nothing. Those hold for any scheduler with
/// this shape, which is why they are worth asserting where the store is.
///
/// **`ProjectWorkspace`'s own behaviour is covered in `Tests/MimicTests/ProjectWorkspaceTests.swift`**
/// — the debounce, the flush on close and on switch, and the identity guard — against the real type.
///
/// ## The divergence, stated rather than left to drift
///
/// `DebounceScheduler` below used to be described as mirroring the production logic. It no longer
/// does, and asserting the difference is cheaper than maintaining a copy that cannot be checked:
///
/// - **Production guards on the project's *identity* after the sleep.** `scheduleAutosave` captures
///   `project.id` before suspending and returns without writing if `currentProject` has become a
///   different project. The model re-reads `currentProject` and writes whatever it finds. That is the
///   divergence `theModelWritesWhateverIsCurrent` pins, so it is a recorded difference rather than a
///   silent one.
/// - **Production has a flush.** Closing or switching projects writes the pending edit immediately,
///   capturing the project by value. The model has no such thing, and adding one here would be
///   modelling a behaviour this file cannot check against its original.
/// - **Production reports.** `autosaveStatus` moves through `.saving` / `.saved` / `.failed` and
///   recents is updated on success. The model counts saves, because the store is what it is about.
@Suite("Autosave Debounce", .serialized, .timeLimit(.minutes(1)))
struct AutosaveDebounceTests {

    /// A deliberately minimal scheduler: cancel-and-resleep, then write. See the suite's note above
    /// for exactly where this and `ProjectWorkspace.scheduleAutosave()` part company.
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

    /// Polls until `predicate` holds or the timeout elapses.
    ///
    /// The waits below used to be flat `Task.sleep(for: .milliseconds(700))` — 200 ms of margin over a
    /// 500 ms debounce, paid on every run and gone the moment a loaded CI box takes longer than that
    /// to reach a SQLite write. Polling ends as soon as the write lands and gives four times the
    /// headroom when it does not.
    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        interval: Duration = .milliseconds(20),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: interval)
        }
        Issue.record("Timed out waiting for condition")
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

        // Nothing may have been written yet — the debounce is the point.
        #expect(scheduler.saveCount == 0)

        try await waitUntil { scheduler.saveCount == 1 }

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

        try await waitUntil { scheduler.saveCount == 1 }

        // The count is the claim: five edits inside one quiet period are one write, not five. Waiting
        // longer must not turn up a second one, so the settle below is a fixed wait on purpose — it is
        // asserting that nothing further happens.
        try await Task.sleep(for: .milliseconds(600))
        #expect(scheduler.saveCount == 1)
        let loaded = try await repo.load(id: project.id)
        #expect(loaded.name == "Mutation 5")
    }

    @Test @MainActor func restoringProjectDoesNotTriggerAutosave() async throws {
        let (scheduler, repo) = try makeScheduler()
        let project = MockProject(name: "Original", serverConfiguration: .default)
        try await repo.save(project)

        scheduler.restoreProject(project)

        // Fixed, and deliberately so: the claim is that nothing happens, and there is no condition to
        // poll for the absence of a write. One debounce period plus margin.
        try await Task.sleep(for: .milliseconds(700))

        #expect(scheduler.saveCount == 0)
        let loaded = try await repo.load(id: project.id)
        #expect(loaded.name == "Original")
    }

    /// The divergence from `ProjectWorkspace.scheduleAutosave()`, pinned so it is a recorded
    /// difference rather than one nobody has noticed.
    ///
    /// Production captures `project.id` before it suspends and, on waking, writes only if
    /// `currentProject` is still that project — a debounced edit for a project that has since been
    /// closed or switched away from is handed to `flushPendingAutosave()` instead. The model has
    /// neither half: it re-reads `currentProject` and writes whatever it finds, so a *different*
    /// project set during the quiet period is what lands.
    ///
    /// The behaviour asserted here is the model's, not the app's. It is asserted at all so that
    /// anyone reading this file for what the app does is told, in a failing test's name, that it is
    /// the wrong file to read.
    @Test("MODEL ONLY: the scheduler here writes whatever is current when it wakes")
    @MainActor
    func theModelWritesWhateverIsCurrent() async throws {
        let (scheduler, repo) = try makeScheduler()
        let first = MockProject(name: "First", serverConfiguration: .default)
        let second = MockProject(name: "Second", serverConfiguration: .default)
        try await repo.save(first)
        try await repo.save(second)

        scheduler.currentProject = first
        scheduler.scheduleAutosave()
        // Inside the quiet period, the project moves out from under the pending write.
        scheduler.currentProject = MockProject(
            id: second.id,
            name: "Second, edited",
            serverConfiguration: second.serverConfiguration,
            createdAt: second.createdAt
        )

        try await waitUntil { scheduler.saveCount == 1 }

        let reloadedSecond = try await repo.load(id: second.id)
        let reloadedFirst = try await repo.load(id: first.id)
        #expect(
            reloadedSecond.name == "Second, edited",
            "the model writes the project that is current when it wakes"
        )
        #expect(
            reloadedFirst.name == "First",
            "and the project the edit belonged to is left as the store had it"
        )
    }
}
