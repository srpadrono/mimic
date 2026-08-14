import Foundation
import Testing
import Domain
import Persistence
@testable import AppFeatures

/// The three arms whose job is to *report* where the journey run stands, driven against an engine
/// holding one cursor while the runtime's published mirror holds another.
///
/// `journeyActivate`, `journeyRestart` and `journeyAdvance` were each repaired a wave apart, every
/// time for the same reason: a reply built from `AppState.activeJourneyStatus` carries the position
/// from *before* the command, because the mirror is refreshed by served traffic and by configuration
/// pushes and a control call arrives between those — or before the first of them, which is when a
/// script's opening poll happens and the mirror is empty. `journeyStatus`, `state` and `reset` were
/// left behind, and they are the three a caller with no window actually reads: docs/CLI.md points a
/// script at `mimic state` after every optimistic reply.
///
/// **The mirror is parked by assignment, never through anything under test.** Each case leaves it on
/// a status no engine here answers with and no document here could produce, so the two possible
/// replies are told apart by their content: the engine's cursor is the repaired behaviour, and
/// ``poisonedName`` is the old one. Revert any of the three arms to `activeJourneyStatus` and the
/// reply carries that name, which is what these assert it does not.
@Suite("Journey cursor reporting")
@MainActor
struct JourneyCursorReportingTests {

    // MARK: - Fixtures

    /// An engine that holds a run and answers from it: ``liveName`` until something restarts the run,
    /// ``restartedName`` afterwards.
    ///
    /// Two names rather than one because `reset --scope journey` has to be shown reporting the run
    /// its own restart produced rather than the one that preceded it. A double whose `journeyStatus()`
    /// ignored the restart could not tell those apart — both reads would answer the same thing, which
    /// is exactly the confusion the arm shipped with.
    private actor CursorEngine: MockServerEngineProtocol {
        static let liveName = "Live in the engine"
        static let restartedName = "Restarted by the engine"

        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation
        private var hasRestarted = false
        private(set) var restartCallCount = 0

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func start(configuration: ServerConfiguration) async throws {}
        func stop() async throws {}
        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {}

        func journeyStatus() async -> JourneyStatus? {
            JourneyStatus.make(
                journey: Journey(name: hasRestarted ? Self.restartedName : Self.liveName),
                state: nil
            )
        }

        func restartJourney() async -> JourneyStatus? {
            hasRestarted = true
            restartCallCount += 1
            return JourneyStatus.make(journey: Journey(name: Self.restartedName), state: nil)
        }
    }

    private struct Session {
        let host: AppControlHost
        /// Held because `AppControlHost` holds the session *weakly*, so nothing else here keeps it
        /// alive. Drop this and every command answers "The Mimic session is no longer available."
        let appState: AppState
        let engine: CursorEngine
    }

    /// The journey the open document holds — a third name, so a reply fabricated from the document
    /// is distinguishable from the engine's answer and from the parked mirror alike.
    private static let documentJourneyName = "Flow"

    /// What the mirror is left holding. Nothing produces it but the assignment below.
    private static let poisonedName = "Poisoned mirror"

    /// A session with one project open, one journey active, and the mirror parked.
    ///
    /// The document is a literal rather than something the command surface built: routing it through
    /// `journeyAddTemplate` and `journeyActivate` would put an arm of the switch under test into the
    /// fixture's own path, and a fixture that fails with the fix reverted proves nothing about it.
    private func makeSession() async throws -> Session {
        let queue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        // Its own defaults suite, so a run cannot inherit — or overwrite — a real recents list or a
        // real window arrangement. `PanelLayoutStore()` would bind to `.standard` and do exactly that.
        let defaults = try #require(
            UserDefaults(suiteName: "JourneyCursorReportingTests.\(UUID().uuidString)")
        )
        let engine = CursorEngine()
        let appState = AppState(
            server: MockServerRuntime(engine: engine),
            projectRepository: GRDBProjectRepository(dbQueue: queue),
            recentProjectsStore: RecentProjectsStore(defaults: defaults),
            panelLayoutStore: PanelLayoutStore(defaults: defaults)
        )

        let journey = Journey(name: Self.documentJourneyName)
        appState.currentProject = MockProject(
            name: "Checkout",
            journeys: [journey],
            activeJourneyID: journey.id
        )

        // Retires every mirror write still outstanding, so the assignment below is the last one.
        //
        // Publishing a project pushes it to the engine, and each push refreshes the mirror from a
        // task of its own; those tasks are in flight here. This awaits the push chain and then takes
        // a newer `journeyStatusTicket`, which is what makes their answers drop instead of landing
        // on top of the parked status a moment later. Without it the mirror holds whatever won a
        // race — and if a refresh won, it holds the engine's own answer, which is the value these
        // tests assert the *reply* carries. That is a test that passes with the arms reverted.
        _ = await appState.server.journeyStatusAfterPendingUpdates()
        appState.server.journeyStatus = JourneyStatus.make(
            journey: Journey(name: Self.poisonedName),
            state: nil
        )

        return Session(
            host: AppControlHost(appState: appState, repository: appState.repository),
            appState: appState,
            engine: engine
        )
    }

    // MARK: - The three arms

    /// The command whose entire job is reporting the cursor was the last one answering from a copy
    /// of it.
    @Test("`journey status` reports the engine's cursor, not the runtime's mirror")
    func journeyStatusReportsTheEngineCursor() async throws {
        let session = try await makeSession()

        let response = await session.host.execute(.journeyStatus)

        #expect(response.ok)
        let status = try #require(response.result?.journeyStatus)
        #expect(
            status.journeyName == CursorEngine.liveName,
            "the cursor came from somewhere other than the engine — the mirror, or the document"
        )
    }

    /// `mimic state` is what docs/CLI.md tells a script to poll after an optimistic reply, so the
    /// mirror's staleness reached the caller least able to notice it: a headless run has no window
    /// rendering the live cursor beside it to disagree.
    @Test("`state` reports the engine's cursor, not the runtime's mirror")
    func stateReportsTheEngineCursor() async throws {
        let session = try await makeSession()

        let response = await session.host.execute(.state)

        #expect(response.ok)
        let state = try #require(response.result?.state)
        // The rest of the report still comes from the session, so a failure below is the cursor
        // changing rather than the state having been built from nothing.
        #expect(state.project?.name == "Checkout")
        #expect(
            state.activeJourney?.journeyName == CursorEngine.liveName,
            "`mimic state` answered with the mirror's cursor rather than the engine's"
        )
    }

    /// The reply that contradicted itself. The restart was dispatched fire-and-forget and the state
    /// built on the very next statement, so one envelope named the journey it had just rewound and
    /// attached the position from before the rewind.
    @Test("`reset --scope journey` reports the cursor its own restart produced")
    func resetReportsThePostRestartCursor() async throws {
        let session = try await makeSession()

        let response = await session.host.execute(.reset(scope: .journey))

        #expect(response.ok)
        // `ControlMessages.reset`'s sentence, pinned as a literal because a script string-matches
        // it — and because it is the half of the reply that was already right.
        #expect(response.result?.message == "Reset journey \"Flow\".")
        let state = try #require(response.result?.state)
        #expect(
            state.activeJourney?.journeyName == CursorEngine.restartedName,
            "the state was built before the restart the same reply reports had reached the engine"
        )
        // Awaited rather than dispatched, so the restart has landed by the time the reply exists.
        #expect(await session.engine.restartCallCount == 1)
    }
}
