import Foundation
import Testing
import Domain
import Persistence
import SpecImport
@testable import AppFeatures

/// The two stale-result guards, gated.
///
/// `ProjectWorkspace.openGeneration` and `ImportWorkflow.parseGeneration` are one mechanism applied
/// to two screens: a slow result that has been superseded must never reach the published state.
/// Both are documented at length where they are declared, and each had a half nothing failed
/// without.
///
/// `ProjectWorkspaceTests` covers the *publish* half of `openGeneration` — create, close, delete and
/// import each superseding an open still in flight, which is the bump `setCurrentProject` makes.
/// What it does not reach is the bump `openProject` makes for itself, and that one is only
/// load-bearing when the **abandoned** open resolves first: with the ticket raised only on publish,
/// two opens share a generation, so whichever load returns first publishes and the other is then
/// refused — which is the original defect exactly, the window left on the project the user clicked
/// away from. `parseGeneration` had nothing at all.
///
/// The three publish doors that are not lifecycle commands are here for the same reason: an edit
/// through `AppState`, and a delete of a project that is not the open one — before it settles and
/// after — each published, or failed to supersede, past a ticket the documentation said they took.
///
/// Every test here needs the same shape: a result that can be parked and released on demand, so the
/// superseded arrival is forced rather than raced.
@Suite("Stale-result guards", .serialized)
@MainActor
struct RaceGuardTests {

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

    /// The same poll for a predicate that has to ask an actor. Named apart from `waitUntil` rather
    /// than overloaded on the closure's effects: two overloads differing only in `async` is exactly
    /// the shape that resolves to whichever one the compiler happens to prefer.
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

    // MARK: - ProjectWorkspace.openGeneration

    /// A store whose loads park **per project id**, so two opens can be resolved in a chosen order.
    ///
    /// `ProjectWorkspaceTests` already carries `GatedLoadRepository`, which releases every parked
    /// load at once. That is the right shape for "one open is in flight while a lifecycle command
    /// arrives", and it cannot express this one: what makes the ticket `openProject` takes
    /// load-bearing is the *first* open's load completing first, and a single latch leaves which of
    /// two parked loads resumes first to the scheduler.
    ///
    /// The row is captured at entry, before the park, so a load released later still has a project
    /// to publish — publishing it is the defect being asserted against, not a `projectNotFound`.
    private actor OrderedLoadRepository: ProjectRepository {
        private var projects: [UUID: MockProject] = [:]
        private var released: Set<UUID> = []
        private var entered: [UUID] = []
        private var heldDeletes: Set<UUID> = []
        private var enteredDeletes: [UUID] = []

        func seed(_ project: MockProject) { projects[project.id] = project }
        func release(_ id: UUID) { released.insert(id) }
        func loadCount(for id: UUID) -> Int { entered.filter { $0 == id }.count }
        func stored(_ id: UUID) -> MockProject? { projects[id] }

        /// Parks the delete of `id` the way the loads park, so a test can hold the window in which
        /// the delete has been asked for and has not settled. Off by default: a delete that returns
        /// at once is what the other tests here want.
        func holdDelete(_ id: UUID) { heldDeletes.insert(id) }
        func releaseDelete(_ id: UUID) { heldDeletes.remove(id) }
        func deleteCount(for id: UUID) -> Int { enteredDeletes.filter { $0 == id }.count }

        func save(_ project: MockProject) async throws { projects[project.id] = project }

        func load(id: UUID) async throws -> MockProject {
            entered.append(id)
            let captured = projects[id]
            // Sleeping rather than spinning, so every hop hands the actor back and `release(_:)` can
            // run while a load is parked.
            while !released.contains(id) {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard let captured else { throw PersistenceError.projectNotFound(id) }
            return captured
        }

        func allProjects() async throws -> [MockProject] { Array(projects.values) }

        func delete(id: UUID) async throws {
            enteredDeletes.append(id)
            while heldDeletes.contains(id) {
                try? await Task.sleep(for: .milliseconds(5))
            }
            projects[id] = nil
        }
    }

    private func makeWorkspace(over repository: OrderedLoadRepository) throws -> ProjectWorkspace {
        let defaults = try #require(UserDefaults(suiteName: "RaceGuardTests.\(UUID().uuidString)"))
        return ProjectWorkspace(
            projectRepository: repository,
            recentProjectsStore: RecentProjectsStore(defaults: defaults)
        )
    }

    /// A whole session over the same parked store, for the test that has to drive a *command* rather
    /// than the workspace directly: the door under test is `AppState.currentProject`'s setter, which
    /// every endpoint, scenario and journey command writes through.
    ///
    /// The runtime is the real one and is never started, which is what every other session-level
    /// suite here does: nothing binds a port until `startServer()`.
    private func makeAppState(over repository: OrderedLoadRepository) throws -> AppState {
        let defaults = try #require(UserDefaults(suiteName: "RaceGuardTests.\(UUID().uuidString)"))
        return AppState(
            projectRepository: repository,
            recentProjectsStore: RecentProjectsStore(defaults: defaults)
        )
    }

    /// Clicking one project, changing your mind and clicking another: two independent loads with no
    /// order between them, and the slower one used to win. Driven with the abandoned open resolving
    /// **first**, which is the only ordering that distinguishes the ticket `openProject` takes from
    /// the one every publish takes.
    @Test("Two opens in quick succession settle on the second, whichever load returns first")
    func theSecondOfTwoOpensDecidesWhatIsShown() async throws {
        let repository = OrderedLoadRepository()
        let service = try makeWorkspace(over: repository)
        let first = MockProject(name: "First")
        let second = MockProject(name: "Second")
        await repository.seed(first)
        await repository.seed(second)

        service.openProject(id: first.id)
        // Parked inside the load before the second open is asked for, so the two are genuinely in
        // flight together rather than merely dispatched together.
        try await waitUntilAsync { await repository.loadCount(for: first.id) == 1 }
        service.openProject(id: second.id)
        try await waitUntilAsync { await repository.loadCount(for: second.id) == 1 }

        await repository.release(first.id)
        // Room for the abandoned open to publish and be seen. The condition is that nothing happens,
        // so this one wait cannot be a poll.
        try await Task.sleep(for: .milliseconds(200))

        #expect(
            service.currentProject == nil,
            "the abandoned open published the project the user had already clicked away from"
        )

        await repository.release(second.id)
        try await waitUntil { service.currentProject?.name == "Second" }
    }

    /// The lost write two back-to-back control commands could produce, with both of them exiting 0.
    ///
    /// `mimic project open` answers "Opening project." while the load is still in flight — the reply
    /// is optimistic by contract — so a `mimic endpoint create` arriving behind it edits the project
    /// that is *still* open. That edit is a publish, and it used to reach `currentProject` through
    /// `AppState`'s setter without raising `openGeneration`: the abandoned load then passed the
    /// generation guard, published the other project, and the autosave debounce woke 500 ms later,
    /// found a project it did not recognise under its `project.id == projectID` guard, and returned
    /// having written nothing. No error, no indicator, and `autosaveStatus` never leaving `.idle` —
    /// the failure mode this app has no way of telling you about, reachable from the CLI.
    @Test("An edit arriving during an open supersedes it, and reaches the store")
    func anEditArrivingDuringAnOpenIsNotLost() async throws {
        let repository = OrderedLoadRepository()
        let appState = try makeAppState(over: repository)
        let open = MockProject(name: "Open")
        let other = MockProject(name: "Other")
        await repository.seed(open)
        await repository.seed(other)

        // The project the session is on when the second open arrives. Released first, so this one
        // load does not park.
        await repository.release(open.id)
        appState.openProject(id: open.id)
        try await waitUntil { appState.currentProject?.id == open.id }

        // `mimic project open Other`: dispatched, parked inside the load, and already answered.
        appState.openProject(id: other.id)
        try await waitUntilAsync { await repository.loadCount(for: other.id) == 1 }

        // `mimic endpoint create` arriving in that window, through the executor and the session's
        // one publish door — the path `AppControlHost` takes for every project-scoped command.
        let added = appState.addEndpoint(name: "Added", method: .get, path: "/added")
        #expect(added != nil, "the executor refused the endpoint, so nothing was published")

        // Released inside the 500 ms debounce window, so a stale publish provably lands before the
        // save wakes rather than by scheduler luck — that ordering is the whole defect.
        await repository.release(other.id)

        try await waitUntilAsync(timeout: .seconds(3)) {
            await repository.stored(open.id)?.endpoints.map(\.path) == ["/added"]
        }
        #expect(
            appState.currentProject?.id == open.id,
            "the superseded open published over the project the edit had just been made to"
        )
    }

    /// The delete/open gap, and why the ticket a delete takes cannot be conditional.
    ///
    /// `deleteProject` published — and so superseded — only when the project it removed was the open
    /// one. With something else open, or nothing, a load parked on the removed row captured it
    /// before the removal, so releasing it opened a project the store no longer has. Permanently:
    /// the delete's arm has already run and will not close it, the recents entry it had just struck
    /// comes back, and the next edit saves the row straight back in. Create, close and import
    /// supersede whatever is loading regardless of which project it is; this was the one publish
    /// door that did not.
    @Test("A settled delete supersedes an open still in flight")
    func aSettledDeleteSupersedesAnInFlightOpen() async throws {
        let repository = OrderedLoadRepository()
        let service = try makeWorkspace(over: repository)
        let doomed = MockProject(name: "Doomed")
        await repository.seed(doomed)

        // Nothing open, so the delete's publish arm is the one that does not run — which is exactly
        // the case its ticket was conditional on.
        service.openProject(id: doomed.id)
        try await waitUntilAsync { await repository.loadCount(for: doomed.id) == 1 }

        service.deleteProject(id: doomed.id)
        try await waitUntilAsync { await repository.stored(doomed.id) == nil }

        await repository.release(doomed.id)
        // Room for the superseded load to publish and be seen. The condition is that nothing
        // happens, so this one wait cannot be a poll.
        try await Task.sleep(for: .milliseconds(200))

        #expect(
            service.currentProject == nil,
            "the superseded open opened a project the delete had already removed from the store"
        )
        #expect(
            service.recentProjects.contains { $0.id == doomed.id } == false,
            "the superseded open put the deleted project's entry back in the list"
        )
    }

    /// The other half of that gap: the window in which the delete has been *asked for* and has not
    /// settled. Nothing has superseded the load yet, and the row it captured is on its way out — so
    /// publishing it leaves the window on a project whose every save is already refused (the
    /// debounce's claim, the flush and `saveCurrentProject` all check the tombstone). An edit made
    /// there is written nowhere, which is the same silent loss from the other side.
    ///
    /// The store's delete is held open for the assertion, so the tombstone is provably still set
    /// when the load publishes.
    @Test("A publish cannot open a project whose delete is already in flight")
    func aPublishCannotOpenAProjectBeingDeleted() async throws {
        let repository = OrderedLoadRepository()
        let service = try makeWorkspace(over: repository)
        let doomed = MockProject(name: "Doomed")
        await repository.seed(doomed)
        await repository.holdDelete(doomed.id)

        service.openProject(id: doomed.id)
        try await waitUntilAsync { await repository.loadCount(for: doomed.id) == 1 }

        service.deleteProject(id: doomed.id)
        try await waitUntilAsync { await repository.deleteCount(for: doomed.id) == 1 }

        await repository.release(doomed.id)
        try await Task.sleep(for: .milliseconds(200))

        #expect(
            service.currentProject == nil,
            "the open published a project whose delete was already in the write chain"
        )

        // Released so the delete settles rather than leaving a parked write behind the test.
        await repository.releaseDelete(doomed.id)
        try await waitUntilAsync { await repository.stored(doomed.id) == nil }
    }

    // MARK: - ImportWorkflow.parseGeneration

    /// Parks a parse until it is released, counting arrivals.
    ///
    /// Cancellation cannot do this job — `parseFile` cancels the task it supersedes, and the parse
    /// runs inside a `Task.detached` that does not inherit cancellation — so a gate is what a test
    /// needs to hold a superseded parse open long enough for the newer one to settle.
    private actor ParseGate {
        private var isOpen = false
        private(set) var arrivals = 0

        func arrive() async {
            arrivals += 1
            // Sleeping rather than spinning, so every hop hands the actor back and `release()` can
            // run while a parse is parked.
            while !isOpen {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        func release() { isOpen = true }
    }

    private static func candidate(path: String) -> ImportCandidate {
        ImportCandidate(
            isSelected: true,
            method: .get,
            path: path,
            suggestedName: "Import GET",
            suggestedGroupTag: nil,
            statusCode: 200,
            responseHeaders: ["Content-Type": "application/json"],
            responseBody: #"{"ok":true}"#,
            responseContentType: .json,
            bodySizeBytes: 11,
            bodySizeExceedsLimit: false,
            isDuplicate: false
        )
    }

    /// Choose a large HAR, realise it was the wrong file, choose a small one: the first parse
    /// finishes second and used to replace the candidates for the file you actually asked for —
    /// under a screen that had already stopped saying it was parsing, so nothing on it suggested the
    /// list was from the abandoned file.
    @Test("A superseded parse cannot replace the candidates of the file that superseded it")
    func aSupersededParseCannotReplaceTheNewerCandidates() async throws {
        let abandoned = ParseGate()
        let workflow = ImportWorkflow(kind: .har)
        let abandonedResult = [Self.candidate(path: "/abandoned")]
        let chosenResult = [Self.candidate(path: "/chosen")]

        workflow.parseFile(
            at: URL(fileURLWithPath: "/tmp/race-abandoned.har"),
            existingEndpoints: [],
            loadData: { _ in Data("abandoned".utf8) },
            parse: { _, _ in
                await abandoned.arrive()
                return abandonedResult
            }
        )
        try await waitUntilAsync { await abandoned.arrivals == 1 }

        workflow.parseFile(
            at: URL(fileURLWithPath: "/tmp/race-chosen.har"),
            existingEndpoints: [],
            loadData: { _ in Data("chosen".utf8) },
            parse: { _, _ in chosenResult }
        )
        try await waitUntil {
            workflow.isParsing == false && workflow.candidates.map(\.path) == ["/chosen"]
        }

        await abandoned.release()
        // Room for the superseded parse to commit and be seen. The condition is that nothing
        // happens, so this one wait cannot be a poll.
        try await Task.sleep(for: .milliseconds(200))

        #expect(
            workflow.candidates.map(\.path) == ["/chosen"],
            "the superseded parse replaced the candidates for the file the user actually chose"
        )
        #expect(workflow.parseError == nil)
        #expect(workflow.isParsing == false)
    }

    /// The other outcome the same guard covers: a superseded parse must not report its *failure*
    /// either. The error belongs to a file the user has already moved on from, and showing it
    /// replaces the running spinner with "Parse error" for a parse that is still going.
    @Test("A superseded parse's failure cannot interrupt the parse that superseded it")
    func aSupersededParseCannotReportItsFailure() async throws {
        enum FixtureError: Error, LocalizedError {
            case unreadable

            var errorDescription: String? { "Unreadable fixture" }
        }

        let abandoned = ParseGate()
        let running = ParseGate()
        let workflow = ImportWorkflow(kind: .openAPI)
        let chosenResult = [Self.candidate(path: "/chosen")]

        workflow.parseFile(
            at: URL(fileURLWithPath: "/tmp/race-abandoned.json"),
            existingEndpoints: [],
            loadData: { _ in Data("abandoned".utf8) },
            parse: { _, _ in
                await abandoned.arrive()
                throw FixtureError.unreadable
            }
        )
        try await waitUntilAsync { await abandoned.arrivals == 1 }

        workflow.parseFile(
            at: URL(fileURLWithPath: "/tmp/race-chosen.json"),
            existingEndpoints: [],
            loadData: { _ in Data("chosen".utf8) },
            parse: { _, _ in
                await running.arrive()
                return chosenResult
            }
        )
        try await waitUntilAsync { await running.arrivals == 1 }

        await abandoned.release()
        try await Task.sleep(for: .milliseconds(200))

        #expect(
            workflow.parseError == nil,
            "the abandoned parse's error replaced the spinner for a parse that is still running"
        )
        #expect(
            workflow.isParsing,
            "the abandoned parse's failure cleared the parsing flag out from under the newer parse"
        )

        await running.release()
        try await waitUntil { workflow.isParsing == false }
        #expect(workflow.candidates.map(\.path) == ["/chosen"])
        #expect(workflow.parseError == nil)
    }
}
