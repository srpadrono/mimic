import Foundation
import Testing
import Domain
import Persistence
@testable import AppFeatures

/// The shutdown flush, under test for the first time.
///
/// This machinery — `installTerminationHandlers`, `handleTerminationSignal`,
/// `handleTerminationRequest`, `startPendingSave`, the drain and the blocking backstop — shipped
/// data loss twice with zero automated coverage: once when neither exit path wrote the debounced
/// edit at all, and once when the fix for that deadlocked every ⌘Q by draining the write chain
/// from under a parked main thread. Nothing here binds a control server or installs a signal
/// handler; `prepareShutdownFlush` wires the session the way `start` does, and the two
/// irreversible steps — ending the process, removing the discovery file — are the injectable
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

    /// What the termination hooks were called with, in order, and how often a quit's reply fired.
    private final class TerminationRecorder {
        var exits: [Int32] = []
        var fileRemovals = 0
        var replies = 0
    }

    // MARK: - The drain-ordering property

    /// Manifestation (e) of the write-ordering class: the draining flush captured `currentProject`
    /// *before* waiting out the write chain and saved it *after* — so quitting just after
    /// `mimic project delete` waited for the delete to land and then wrote the captured row straight
    /// back into the store it had just been deleted from. The final save goes through the chain's
    /// own door now — `saveCurrentProject`, enqueued once the drain has settled — and after a
    /// drained delete it finds nothing open and writes nothing.
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

    // MARK: - The quit (⌘Q) drain

    /// The case the old ⌘Q path failed by construction. Quit used to run from the `willTerminate`
    /// observer, which parks the main thread — and the write chain is main-actor work, so that
    /// path could not drain and instead captured `currentProject` before the chained delete ran,
    /// then raced its bare save against the delete: quitting behind an acknowledged
    /// `mimic project delete` lost the delete or resurrected the row, on a coin flip.
    /// `MimicAppDelegate` answers `.terminateLater` and quits through `handleTerminationRequest`
    /// now, which drains the chain with the runloop still alive and routes the final save through
    /// `saveCurrentProject` — nothing open after the drained delete, nothing written.
    @Test("A quit arriving while a chained delete is in flight does not resurrect the row")
    func quitDuringAChainedDeleteDoesNotResurrectTheRow() async throws {
        let context = try makeContext()
        let appState = context.appState

        appState.createProject(name: "Doomed at quit", port: 9203)
        let id = try #require(appState.currentProject?.id)
        await appState.projects.awaitPendingStoreWrites()
        #expect((try? await context.repository.load(id: id)) != nil, "the seed never reached the store")

        let recorder = TerminationRecorder()
        context.coordinator.removeDiscoveryFile = { recorder.fileRemovals += 1 }

        // The delete is enqueued and unrun when the quit lands — same actor, no suspension between
        // the two calls — which is exactly the shape that used to resurrect the row.
        appState.deleteProject(id: id)
        context.coordinator.handleTerminationRequest { recorder.replies += 1 }

        // The credential drops synchronously, before any waiting — this door keeps the same
        // file-first promise the signal path makes.
        #expect(recorder.fileRemovals == 1)

        try await waitUntil { recorder.replies == 1 }
        await appState.projects.awaitPendingStoreWrites()

        #expect(
            (try? await context.repository.load(id: id)) == nil,
            "the quit drain saved the project the chained delete had just removed"
        )
    }

    /// The other half of the quit contract: the reply is what tells AppKit to finish terminating,
    /// so a drain that wedges is a quit that hangs. The poll in `flushPendingSave` bounds the wait,
    /// and this holds the whole door to that bound — with the debounced edit written on the way,
    /// which is what the drain is *for*.
    @Test("The quit drain writes the open project and replies inside the deadline")
    func quitDrainSavesTheOpenProjectAndReplies() async throws {
        let context = try makeContext()
        let appState = context.appState

        appState.createProject(name: "Quit request", port: 9205)
        let id = try #require(appState.currentProject?.id)
        await appState.projects.awaitPendingStoreWrites()

        // Edited, with no autosave scheduled: the drain saves unconditionally, because a pending
        // debounce is invisible from the coordinator and the write is idempotent.
        appState.currentProject?.name = "Edited at quit request"

        let recorder = TerminationRecorder()
        context.coordinator.removeDiscoveryFile = { recorder.fileRemovals += 1 }

        let start = ContinuousClock.now
        context.coordinator.handleTerminationRequest { recorder.replies += 1 }
        try await waitUntil(timeout: .seconds(4)) { recorder.replies == 1 }
        let elapsed = ContinuousClock.now - start

        #expect(
            elapsed < .seconds(ControlPlaneCoordinator.shutdownFlushTimeoutSeconds),
            "the quit drain ran out its deadline — the shape of the documented \u{2318}Q deadlock"
        )
        let stored = try await context.repository.load(id: id)
        #expect(stored.name == "Edited at quit request")
    }

    /// The retained dispatch, end to end. `AppState.importProject` returns before its task has
    /// run, so at quit time the write chain may not have heard of the import at all — the handle
    /// `importTask` carries is what lets the drain order itself behind the dispatch instead of
    /// draining an empty chain and exiting with the document unwritten. The quit lands with no
    /// suspension after the dispatch, the worst shape the gap has.
    @Test("A quit arriving right behind an import dispatch persists the imported document")
    func quitDrainWaitsForTheImportDispatch() async throws {
        let context = try makeContext()
        let document = MockProject(name: "Imported at quit")

        let recorder = TerminationRecorder()
        context.coordinator.removeDiscoveryFile = { recorder.fileRemovals += 1 }

        context.appState.importProject(document, activate: false)
        context.coordinator.handleTerminationRequest { recorder.replies += 1 }

        try await waitUntil { recorder.replies == 1 }

        #expect(
            (try? await context.repository.load(id: document.id)) != nil,
            "the quit drain finished before the import dispatch had joined the write chain"
        )
    }

    // MARK: - The blocking (`willTerminate`) backstop

    /// The backstop blocks the main thread for up to the whole deadline, and its documented
    /// failure mode is a flush that *needs* that thread: draining the main-actor write chain from
    /// under a parked main thread deadlocked every quit, spent the full two seconds, and saved
    /// nothing — which is why the backstop saves bare and never drains. This asserts both halves:
    /// the edit landed, and the flush returned well inside the deadline. A regression that makes
    /// this path need the parked main actor fails the elapsed bound; one that stops writing fails
    /// the load.
    @Test("The blocking backstop writes the open project while the main thread is held")
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

    /// Both termination doors route the final save through the chain now, so the backstop — whose
    /// save is bare, off the chain, because a parked main thread can drain nothing — must stand
    /// down once a drain has run. If it did not, every ordinary quit would end on exactly the
    /// unordered write the drain exists to retire, free to land after anything accepted since the
    /// reply.
    @Test("The blocking backstop stands down once the quit drain has run")
    func backstopStandsDownOnceTheQuitDrainHasRun() async throws {
        let context = try makeContext()
        let appState = context.appState

        appState.createProject(name: "Kept at quit", port: 9204)
        let id = try #require(appState.currentProject?.id)
        await appState.projects.awaitPendingStoreWrites()

        let recorder = TerminationRecorder()
        context.coordinator.removeDiscoveryFile = { recorder.fileRemovals += 1 }
        context.coordinator.handleTerminationRequest { recorder.replies += 1 }
        try await waitUntil { recorder.replies == 1 }

        // An edit surfacing after the drain replied. Nothing may write it on the way out — the
        // backstop running here would push it to the store outside the chain.
        appState.currentProject?.name = "Edit after the drain replied"
        context.coordinator.flushPendingSaveBlocking()

        let stored = try await context.repository.load(id: id)
        #expect(
            stored.name == "Kept at quit",
            "the backstop wrote a second, out-of-chain copy of the shutdown save"
        )
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
