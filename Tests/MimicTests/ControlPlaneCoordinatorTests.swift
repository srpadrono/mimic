import Foundation
import Testing
import Domain
import Persistence
@testable import AppFeatures

/// The shutdown flush, under test for the first time.
///
/// This machinery — `installTerminationHandlers`, `handleTerminationSignal`, `startPendingSave`,
/// both flush paths — shipped data loss twice with zero automated coverage: once when neither exit
/// path wrote the debounced edit at all, and once when the fix for that deadlocked every ⌘Q by
/// draining the write chain from under a parked main thread. Nothing here binds a control server or
/// installs a signal handler; `prepareShutdownFlush` wires the session the way `start` does, and the
/// two irreversible steps — ending the process, removing the discovery file — are the injectable
/// hooks the coordinator now carries, so a test can drive the real path without exiting the runner
/// or touching a real instance's credential file.
@Suite("Control plane coordinator shutdown flush", .serialized)
@MainActor
struct ControlPlaneCoordinatorTests {

    private struct Context {
        let coordinator: ControlPlaneCoordinator
        let appState: AppState
        let repository: GRDBProjectRepository
    }

    private func makeContext() throws -> Context {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)
        // Its own defaults suite, so a run cannot inherit — or overwrite — a real recents list or a
        // real window arrangement.
        let defaults = try #require(
            UserDefaults(suiteName: "ControlPlaneCoordinatorTests.\(UUID().uuidString)")
        )
        let appState = AppState(
            projectRepository: repository,
            recentProjectsStore: RecentProjectsStore(defaults: defaults),
            panelLayoutStore: PanelLayoutStore(defaults: defaults)
        )
        let coordinator = ControlPlaneCoordinator()
        coordinator.prepareShutdownFlush(appState: appState, repository: repository)
        return Context(coordinator: coordinator, appState: appState, repository: repository)
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

    /// What the two termination hooks were called with, in order.
    private final class TerminationRecorder {
        var exits: [Int32] = []
        var fileRemovals = 0
    }

    // MARK: - The drain-ordering property

    /// Manifestation (e) of the write-ordering class: the draining flush captured `currentProject`
    /// *before* waiting out the write chain and saved it *after* — so quitting just after
    /// `mimic project delete` waited for the delete to land and then wrote the captured row straight
    /// back into the store it had just been deleted from. The project is re-read once the chain is
    /// drained now, and a drained delete leaves nothing to save.
    @Test("The draining flush cannot resurrect a project a chained delete is removing")
    func drainingFlushDoesNotResurrectADeletedProject() async throws {
        let context = try makeContext()
        let appState = context.appState

        appState.createProject(name: "Doomed", port: 9200)
        let id = try #require(appState.currentProject?.id)
        await appState.projects.awaitPendingStoreWrites()
        #expect((try? await context.repository.load(id: id)) != nil, "the seed never reached the store")

        // The delete is chained and has not run yet — `flushPendingSave` is same-actor, so nothing
        // can slip in between. The flush therefore starts with `currentProject` still naming the
        // doomed project, which is exactly the shape the capture-before-drain bug needs.
        appState.deleteProject(id: id)
        await context.coordinator.flushPendingSave()
        await appState.projects.awaitPendingStoreWrites()

        #expect(
            (try? await context.repository.load(id: id)) == nil,
            "the shutdown flush saved the project the drain had just deleted"
        )
    }

    // MARK: - The blocking (⌘Q) path

    /// The ⌘Q path blocks the main thread for up to the whole deadline, and its documented failure
    /// mode is a flush that *needs* that thread: draining the main-actor write chain from under a
    /// parked main thread deadlocked every quit, spent the full two seconds, and saved nothing. So
    /// this asserts both halves — the edit landed, and the flush returned well inside the deadline.
    /// A regression back into the deadlock fails the elapsed bound; a flush that stops writing
    /// fails the load.
    @Test("The blocking quit flush writes the open project while the main thread is held")
    func blockingFlushSavesTheOpenProjectInsideTheDeadline() async throws {
        let context = try makeContext()
        let appState = context.appState

        appState.createProject(name: "Quit", port: 9201)
        let id = try #require(appState.currentProject?.id)
        await appState.projects.awaitPendingStoreWrites()

        // Edited, with no autosave scheduled: the flush writes unconditionally, because a pending
        // debounce is invisible from the coordinator and the write is idempotent.
        appState.currentProject?.name = "Edited at quit"

        let start = ContinuousClock.now
        context.coordinator.flushPendingSaveBlocking()
        let elapsed = ContinuousClock.now - start

        #expect(
            elapsed < .seconds(ControlPlaneCoordinator.shutdownFlushTimeoutSeconds),
            "the blocking flush ran out its deadline — the shape of the documented \u{2318}Q deadlock"
        )
        let stored = try await context.repository.load(id: id)
        #expect(stored.name == "Edited at quit")
    }

    // MARK: - The signal (`mimic app stop`) path

    /// The whole `SIGTERM` contract, minus the dispatch source that feeds it: the credential file
    /// goes first, the store is flushed, and only then does the process end — with a second signal
    /// meaning "done waiting" and ending it immediately.
    @Test("A termination signal removes the discovery file, flushes the store, then exits")
    func terminationSignalFlushesThenExits() async throws {
        let context = try makeContext()
        let appState = context.appState

        appState.createProject(name: "Signalled", port: 9202)
        let id = try #require(appState.currentProject?.id)
        await appState.projects.awaitPendingStoreWrites()
        appState.currentProject?.name = "Edited before the signal"

        let recorder = TerminationRecorder()
        context.coordinator.removeDiscoveryFile = { recorder.fileRemovals += 1 }
        context.coordinator.exitProcess = { code in recorder.exits.append(code) }

        context.coordinator.handleTerminationSignal()
        // The file drops synchronously, before the flush's wait — it is credential material, and a
        // flush that times out must not be able to leave a live token on disk.
        #expect(recorder.fileRemovals == 1)
        #expect(recorder.exits.isEmpty)

        try await waitUntil { recorder.exits == [0] }

        // The exit hook fired only after the flush, so the edit is already in the store.
        let stored = try await context.repository.load(id: id)
        #expect(stored.name == "Edited before the signal")

        // Signalled again after termination has begun: exits at once, dropping the file again on
        // the way — the one promise this path keeps is that it always ends.
        context.coordinator.handleTerminationSignal()
        #expect(recorder.exits == [0, 0])
        #expect(recorder.fileRemovals == 2)
    }
}
