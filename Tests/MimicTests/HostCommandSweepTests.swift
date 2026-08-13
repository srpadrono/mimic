import Foundation
import Testing
import Domain
import Persistence
@testable import AppFeatures

/// Drives every `CommandKind` through the app's control host — the host every `mimic` invocation
/// reaches — and through `ProjectCommandExecutor`, so the whole partition `CommandKind.scope`
/// declares is exercised from this one file.
///
/// **This file replaced `HostParityTests`.** That suite drove two hosts and asserted they agreed,
/// because the tree carried two `ControlHost` conformances: `AppControlHost` over the live session,
/// and `MimicControlService`, a self-contained service that owned its own repository and engine —
/// built, tested, and constructed by nothing in production. The owner resolved that fork by deleting
/// the service (see "One host" in AGENTS.md), which turned every parity comparison into a tautology:
/// there is nothing left to agree with. What parity was really guarding survives here in a stronger
/// form — the assertions that compared host A to host B now pin host A to the *literal* answer, so a
/// regression fails against a recorded value instead of against a second copy that might have
/// drifted the same way.
///
/// The sweeps are the part the Definition of Done leans on (AGENTS.md, "CLI and Control Plane"):
/// `sample(for:)` is a switch over `CommandKind` with no `default`, so a new command stops this file
/// compiling until a payload exists, and the sweeps then fail until the host and the executor answer
/// it. Neither dispatch switch is compile-enforced — both end in a `default:` that throws — so these
/// tests are the enforcement.
@Suite("Host command sweep", .serialized)
@MainActor
struct HostCommandSweepTests {

    // MARK: - Fixtures

    /// One window-hosted session over an in-memory store.
    private struct Session {
        let host: AppControlHost
        /// Held because `AppControlHost` holds the session *weakly*, so nothing else here keeps it
        /// alive. Drop this and every command answers "The Mimic session is no longer available." —
        /// a suite that would look like a broken host rather than a freed one.
        let appState: AppState
        /// The engine behind the runtime, so a lifecycle command can be swept without a socket.
        let engine: SweepStubEngine
    }

    /// An engine that serves nothing and reports no journey.
    ///
    /// Every command this suite drives needs neither a bound port nor served traffic, and the host
    /// reaches the engine only through `MockServerRuntime`. A stub keeps the sweep deterministic and
    /// keeps it from opening a socket — which is also what lets the seeded sweep below drive
    /// `serverStart`: the parity suite this file replaced had to skip it, because its *other* host
    /// held a real `MockServerEngine` that would have bound a real port.
    private actor SweepStubEngine: MockServerEngineProtocol {
        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation
        private(set) var startedPorts: [Int] = []
        private(set) var stopCount = 0

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func start(configuration: ServerConfiguration) async throws {
            // Nothing binds a port here; the runtime only needs the call to return.
            startedPorts.append(configuration.port)
        }

        func stop() async throws { stopCount += 1 }

        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {}
    }

    private func makeSession() throws -> Session {
        let queue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        // Its own defaults suite, so a run cannot inherit — or overwrite — a real recents list or a
        // real window arrangement. `PanelLayoutStore()` would bind to `.standard` and do exactly that.
        let defaults = try #require(UserDefaults(suiteName: "HostCommandSweepTests.\(UUID().uuidString)"))
        let engine = SweepStubEngine()
        let appState = AppState(
            server: MockServerRuntime(engine: engine),
            projectRepository: GRDBProjectRepository(dbQueue: queue),
            recentProjectsStore: RecentProjectsStore(defaults: defaults),
            panelLayoutStore: PanelLayoutStore(defaults: defaults)
        )
        return Session(
            host: AppControlHost(appState: appState, repository: appState.repository),
            appState: appState,
            engine: engine
        )
    }

    /// Opens a project through the command surface rather than around it. The reply is optimistic —
    /// the window answers before the write lands — but the project is open synchronously, which is
    /// what the rest of the suite needs. A seed that failed would make every downstream assertion
    /// meaningless, so the reply is required to carry a result.
    private func seedProject(
        _ session: Session,
        name: String = "Checkout",
        port: Int = 9099
    ) async throws {
        let response = await session.host.execute(.projectCreate(name: name, port: port))
        _ = try #require(response.result, "the host did not open the seed project")
    }

    // MARK: - Routing: every kind reaches an implementation

    /// One payload per ``CommandKind``, in a switch with **no `default`**.
    ///
    /// That is the whole point of writing it out rather than importing a list: adding a `CommandKind`
    /// stops this file compiling until somebody supplies a sample, so the sweeps below cannot
    /// silently stop covering the command that was just added. A `default` here — or an array of
    /// literals like the one `DomainTests` keeps — would turn "every command is routed" back into
    /// "every command somebody remembered".
    ///
    /// The payloads are deliberately awkward: ids that match nothing, references to endpoints an
    /// empty project does not have. What is under test is *routing*, not success.
    ///
    /// `DomainTests.ControlCommandSamples` is the same list for the executor's own sweeps. It cannot
    /// be shared — a test target is a module, and `MimicTests` cannot import `DomainTests` — so the
    /// duplication is real. It is compiler-checked on both sides, which is the difference between two
    /// lists that must agree and two lists that will drift.
    static func sample(for kind: CommandKind) -> ControlCommand {
        switch kind {
        case .ping: .ping
        case .describeCommands: .describeCommands
        case .state: .state
        case .reset: .reset(scope: .all)
        case .projectList: .projectList
        case .projectCreate: .projectCreate(name: "Swept", port: 9098)
        case .projectOpen: .projectOpen(project: .name("Swept"))
        case .projectClose: .projectClose
        case .projectDelete: .projectDelete(project: .name("Swept"))
        case .projectRename: .projectRename(name: "Renamed")
        case .projectDuplicate: .projectDuplicate(project: .name("Swept"))
        case .projectExport: .projectExport(project: nil)
        case .projectImport: .projectImport(project: MockProject(name: "Swept import"), activate: false)
        case .serverStart: .serverStart(port: nil)
        case .serverStop: .serverStop
        case .serverStatus: .serverStatus
        case .serverConfigure: .serverConfigure(port: 9097, globalDelayMs: 10)
        case .endpointList: .endpointList
        case .endpointGet: .endpointGet(endpoint: .route(.get, "/a"))
        case .endpointCreate: .endpointCreate(name: "A", method: .get, path: "/a", spec: nil)
        case .endpointUpdate: .endpointUpdate(endpoint: .route(.get, "/a"), spec: EndpointSpec(delayMs: 5))
        case .endpointDelete: .endpointDelete(endpoint: .route(.get, "/a"))
        case .endpointDuplicate: .endpointDuplicate(endpoint: .route(.get, "/a"))
        case .scenarioList: .scenarioList(endpoint: .route(.get, "/a"))
        case .scenarioCreate: .scenarioCreate(endpoint: .route(.get, "/a"), name: "S", spec: nil)
        case .scenarioUpdate:
            .scenarioUpdate(endpoint: .route(.get, "/a"), scenario: .name("S"), spec: ScenarioSpec(statusCode: 201))
        case .scenarioDelete: .scenarioDelete(endpoint: .route(.get, "/a"), scenario: .name("S"))
        case .scenarioActivate: .scenarioActivate(endpoint: .route(.get, "/a"), scenario: .name("S"))
        case .journeyList: .journeyList
        case .journeyGet: .journeyGet(journey: .name("Flow"))
        case .journeyCreate: .journeyCreate(name: "Flow", spec: nil)
        case .journeyTemplateList: .journeyTemplateList
        case .journeyAddTemplate: .journeyAddTemplate(templateID: "payment-retry", name: "Flow")
        case .journeyUpdate: .journeyUpdate(journey: .name("Flow"), spec: JourneySpec(completion: .restart))
        case .journeyDelete: .journeyDelete(journey: .name("Flow"))
        case .journeyDuplicate: .journeyDuplicate(journey: .name("Flow"))
        case .journeyStepAdd:
            .journeyStepAdd(
                journey: .name("Flow"),
                step: JourneyStepSpec(method: .get, path: "/a", statusCode: 200),
                atIndex: nil
            )
        case .journeyStepsAdd:
            .journeyStepsAdd(
                journey: .name("Flow"),
                steps: [JourneyStepSpec(method: .get, path: "/a", statusCode: 200)],
                atIndex: nil
            )
        case .journeyStepUpdate:
            .journeyStepUpdate(journey: .name("Flow"), step: .index(0), spec: JourneyStepSpec(statusCode: 500))
        case .journeyStepRemove: .journeyStepRemove(journey: .name("Flow"), step: .index(0))
        case .journeyStepMove: .journeyStepMove(journey: .name("Flow"), step: .index(0), toIndex: 1)
        case .journeyActivate: .journeyActivate(journey: .name("Flow"))
        case .journeyRestart: .journeyRestart
        case .journeyAdvance: .journeyAdvance
        case .journeyStatus: .journeyStatus
        case .logList: .logList(limit: 5, unmatchedOnly: nil)
        case .logClear: .logClear
        }
    }

    /// The code the host answers with from the arm that means "nothing here handles this command".
    ///
    /// `AppControlHost.perform` ends in a `default:` that reports exactly that, built with
    /// `ControlError.internalFailure` — so this is read from the constructor rather than written out,
    /// and cannot drift from it.
    ///
    /// It is `internalFailure`'s *general* code, which the host also uses for an unexpected error it
    /// could not classify. So a failure here could in principle be one of those instead. That is why
    /// every assertion below prints the message: `"… is host-scoped but the app's control host does
    /// not implement it."` is unmistakable, and anything else in that slot is a different bug worth
    /// reading rather than a false alarm worth suppressing.
    static let unimplementedCommandCode = ControlError.internalFailure("").code

    /// The gap the old parity suite was one test short of closing, kept closed here.
    ///
    /// A *new* host-scoped command, implemented nowhere, compiles clean — the dispatch switch ends in
    /// a `default:` — and surfaces at runtime as `internal.failure`, after `mimic commands` has
    /// already advertised it to whatever was driving the instance. This sweep is what fails instead.
    ///
    /// Driven with **no project open**, which is the state that makes the sweep safe as well as
    /// complete: every host-scoped arm is reached, and the ones that need a document refuse with
    /// `project.noneOpen` before they can touch a store, a socket or an engine.
    @Test("Every host-scoped command is answered by the host, not left to the unimplemented arm")
    func everyHostScopedCommandIsRouted() async throws {
        for kind in CommandKind.allCases where kind.scope == .host {
            let session = try makeSession()
            let response = await session.host.execute(Self.sample(for: kind))
            #expect(
                response.error?.code != Self.unimplementedCommandCode,
                "\(kind.rawValue): the host has no arm for it — \(response.error?.message ?? "")"
            )
        }
    }

    /// The same sweep once a project is open, because "no project is open" is a legitimate answer and
    /// a command that only ever produced it would pass the sweep above without ever reaching its own
    /// arm.
    ///
    /// Nothing is skipped — including `serverStart`, which the parity suite this replaced had to
    /// leave out because its second host held a real engine that would have bound a real port. Here
    /// the engine is ``SweepStubEngine``, whose `start` records the port and returns.
    @Test("Every host-scoped command reaches its own arm with a project open")
    func everyHostScopedCommandIsRoutedWithAProjectOpen() async throws {
        for kind in CommandKind.allCases where kind.scope == .host {
            let session = try makeSession()
            try await seedProject(session)
            let response = await session.host.execute(Self.sample(for: kind))
            #expect(
                response.error?.code != Self.unimplementedCommandCode,
                "\(kind.rawValue): the host has no arm for it — \(response.error?.message ?? "")"
            )
        }
    }

    /// The mirror on the other side of the line, so one file covers the whole partition: a
    /// project-scoped command must be applied by ``ProjectCommandExecutor`` rather than declined to a
    /// host that would then report "no project is open" with one open.
    ///
    /// `DomainTests` runs this against its own sample list; running it here against *this* file's
    /// list is what makes the two lists agree about something rather than merely both existing.
    @Test("Every project-scoped command is applied by the executor")
    func everyProjectScopedCommandIsAppliedByTheExecutor() {
        for kind in CommandKind.allCases where kind.scope == .project {
            var project = MockProject(name: "Swept")
            do {
                let outcome = try ProjectCommandExecutor.apply(Self.sample(for: kind), to: &project)
                #expect(outcome != nil, "\(kind.rawValue) is project-scoped and was declined by the executor")
            } catch let error as ControlError {
                // Refusing is still answering: most of these name an endpoint, scenario or journey the
                // empty fixture does not have. What must not appear is the executor's own "I have no
                // arm for this" code.
                #expect(
                    error.code != Self.unimplementedCommandCode,
                    "\(kind.rawValue) reached the executor's unimplemented tail: \(error.message)"
                )
            } catch {
                Issue.record("\(kind.rawValue) failed with a non-ControlError: \(error)")
            }
        }
    }

    // MARK: - Answers pinned to their literal values

    /// These used to be parity assertions — "the window answers what the service answers" — and each
    /// is now pinned to the recorded value instead, which is the stronger claim: two hosts could
    /// drift together, a literal cannot.

    @Test("An invalid document is refused before it is stored")
    func anInvalidImportIsRefusedBeforeStoring() async throws {
        let session = try makeSession()
        try await seedProject(session)

        let broken = MockProject(
            name: "Broken",
            serverConfiguration: ServerConfiguration(port: 70_000, globalDelayMs: 0)
        )
        let response = await session.host.execute(.projectImport(project: broken, activate: false))
        #expect(response.ok == false)
        #expect(response.error?.code == "request.invalid")

        // The reply cannot show the half that matters — a refused import and an accepted one both
        // leave the caller holding one response — so the store says whether anything landed.
        let listed = await session.host.execute(.projectList)
        #expect(listed.result?.projects?.map(\.name) == ["Checkout"])
    }

    @Test("The stored projects are listed with the port and counts each one really has")
    func projectListReportsTheStoredProjects() async throws {
        let session = try makeSession()
        try await seedProject(session, name: "Checkout", port: 9099)
        _ = await session.host.execute(.endpointCreate(name: "Login", method: .post, path: "/login", spec: nil))
        _ = await session.host.execute(.journeyAddTemplate(templateID: "payment-retry", name: "Flow"))

        let listed = await session.host.execute(.projectList)
        let projects = try #require(listed.result?.projects)
        #expect(projects.count == 1)
        // The three the host used to fabricate. Each is asserted against the value the project
        // actually holds, so a listing that fell back to the defaults again fails here.
        #expect(projects.first?.name == "Checkout")
        #expect(projects.first?.port == 9099)
        #expect(projects.first?.endpointCount == 1)
        #expect(projects.first?.journeyCount == 1)
    }

    /// `projectExport` takes a project reference and honours it. The arm used to bind no associated
    /// value at all — `case .projectExport:` — so the reference was dropped on the floor: `mimic
    /// project export Other` returned whatever happened to be open, and naming nothing returned a
    /// document instead of an error.
    ///
    /// The open project is answered out of the session rather than re-read from the store, because an
    /// export taken straight after an edit has to contain that edit, and the edit is sitting in the
    /// autosave debounce. Anything else exists only in the store.
    @Test("Export resolves the project reference it was given")
    func projectExportHonoursItsReference() async throws {
        let session = try makeSession()
        try await seedProject(session, name: "Checkout")

        let missing = await session.host.execute(.projectExport(project: .name("Nonexistent")))
        #expect(missing.ok == false)
        #expect(missing.error?.code == "project.notFound")

        let named = await session.host.execute(.projectExport(project: .name("Checkout")))
        #expect(named.result?.project?.name == "Checkout")

        let open = await session.host.execute(.projectExport(project: nil))
        #expect(open.result?.project?.name == "Checkout")
    }

    /// The open project counts whether or not the store has caught up with it: `projectCreate`
    /// answers before its write lands, so a script that creates a project and immediately names it
    /// would be told it does not exist if resolution went only to the store.
    @Test("A reference naming the open project resolves even before its write has landed")
    func theOpenProjectResolvesWithoutWaitingForTheStore() async throws {
        let session = try makeSession()
        let created = await session.host.execute(.projectCreate(name: "Just created", port: 9098))
        #expect(created.ok)

        let exported = await session.host.execute(.projectExport(project: .name("Just created")))
        #expect(exported.result?.project?.name == "Just created")
    }

    /// A project id that names nothing is refused. The host used to take `ref.id` on trust and search
    /// only when it had a name instead, so `mimic project delete --id <any uuid>` answered "Deleted
    /// the project." having deleted nothing.
    ///
    /// All three are driven, rather than letting `projectDelete` stand in for them: they took the
    /// same shape by having been written the same way, which is exactly the property that stops
    /// holding when somebody edits one of them.
    @Test(
        "An unknown project reference is refused",
        arguments: [
            ControlCommand.projectDelete(project: .id(UUID())),
            .projectOpen(project: .id(UUID())),
            .projectDuplicate(project: .id(UUID())),
            .projectDelete(project: .name("Nonexistent")),
        ]
    )
    func anUnknownProjectReferenceIsRefused(command: ControlCommand) async throws {
        let session = try makeSession()
        try await seedProject(session)

        let response = await session.host.execute(command)
        #expect(response.ok == false)
        #expect(response.error?.code == "project.notFound")
    }

    /// A port outside 1–65535 is refused, and refused before anything is created.
    ///
    /// `AppControlHost.projectCreate` used to run no validator at all, and nothing downstream of it
    /// does either — `AppState.createProject` hands the number straight to a `ServerConfiguration` —
    /// while the arm one screen above it, `serverStart`, had been validating the same value through
    /// the same validator all along.
    @Test("An out-of-range port is refused on create, and creates nothing")
    func anInvalidPortIsRefusedOnProjectCreate() async throws {
        let session = try makeSession()

        let response = await session.host.execute(.projectCreate(name: "Bad port", port: 70_000))
        #expect(response.ok == false)
        #expect(response.error?.code == "request.invalid")

        let listed = await session.host.execute(.projectList)
        #expect(listed.result?.projects?.isEmpty == true)
    }
}
