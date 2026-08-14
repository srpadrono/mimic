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
/// Both tests need the same shape: a result that can be parked and released on demand, so the
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

        func seed(_ project: MockProject) { projects[project.id] = project }
        func release(_ id: UUID) { released.insert(id) }
        func loadCount(for id: UUID) -> Int { entered.filter { $0 == id }.count }

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

        func delete(id: UUID) async throws { projects[id] = nil }
    }

    /// Clicking one project, changing your mind and clicking another: two independent loads with no
    /// order between them, and the slower one used to win. Driven with the abandoned open resolving
    /// **first**, which is the only ordering that distinguishes the ticket `openProject` takes from
    /// the one every publish takes.
    @Test("Two opens in quick succession settle on the second, whichever load returns first")
    func theSecondOfTwoOpensDecidesWhatIsShown() async throws {
        let repository = OrderedLoadRepository()
        let defaults = try #require(UserDefaults(suiteName: "RaceGuardTests.\(UUID().uuidString)"))
        let service = ProjectWorkspace(
            projectRepository: repository,
            recentProjectsStore: RecentProjectsStore(defaults: defaults)
        )
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
