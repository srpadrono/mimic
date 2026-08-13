import Foundation
import Testing
import ControlPlane
import Domain
import MockServerEngine
import Persistence
@testable import AppFeatures

/// The two `ControlHost` conformances, asked the same questions side by side.
///
/// `AppControlHost` maps a command onto the live session behind the window; `MimicControlService`
/// owns a repository and an engine of its own. They are meant to answer identically, and every
/// divergence between them so far was found by *reading* the two files next to each other — never by
/// a test, because until this suite existed no test drove both. `Tests/ControlPlaneTests` covers the
/// service alone and the `AppControlHost` cases in `AppStateAndViewTests` cover the host alone; two
/// green suites prove nothing about whether the two agree.
///
/// What "agree" means here is deliberately narrow, because over-asserting would fail this suite for
/// things that are not defects:
///
/// - **`ok`**, always. A command that succeeds against one instance and fails against the other is a
///   divergence whatever either of them says about it.
/// - **the error `code`**, which is the part a script branches on. Codes come from `ControlError`'s
///   own constructors in Domain, so two hosts reaching the same failure really do produce the same
///   string — a difference there is drift, not wording.
/// - **which result fields are populated**, compared as the JSON keys `ControlCoding` writes. A
///   caller that reads `result.project` is broken by its absence however friendly the message is.
/// - **what is in those fields** — the encoded `ControlResult`, value for value, minus an explicit
///   allowance list.
///
/// The last of those is the one that matters, and it is what this suite was missing. Comparing the
/// key set alone let two hosts agree perfectly while answering with different ports, counts, names
/// and timestamps — and one of them was doing exactly that. `projectList` was answered from the
/// window's recents cache, so every project the session did not have open was reported as serving on
/// `ServerConfiguration.default.port` with zero endpoints and zero journeys, and every row carried a
/// `modifiedAt` of `Date()`; `projects` was populated on both sides, so "host parity" read green.
///
/// Two things are normalised before the values are compared, because they are properties of the
/// *fixture* rather than of either host: UUIDs, which each host mints independently and which are
/// replaced by a placeholder that still asserts the field's presence (``isMintedIdentifier(key:value:)``),
/// and the wall-clock timestamps in ``universalAllowances``. Everything else that is allowed to
/// differ is named per command in ``allowancesByCommand``, each entry carrying the reason.
///
/// Prose is therefore compared as well, and the two sentences this suite once declined to pin are no
/// longer treated alike. `logClear` builds the same sentence from the same count in both files and is
/// now held to it — a wording change on one side should fail here. `ping` stays unpinned, but for a
/// reason rather than a preference: its sentence carries this instance's pid and mode, which two real
/// instances do not share, so it is allowed for the same reason `state`'s `pid` is. Where a
/// difference is itself the thing being pinned, see ``contractDifferences`` and the `DIVERGENCE`
/// tests.
@Suite("Host parity", .serialized)
@MainActor
struct HostParityTests {

    // MARK: - Fixtures

    /// One window-hosted session and one headless service, each over its own in-memory store.
    ///
    /// Separate stores, not one shared queue: the window's host writes through `AppState`'s autosave
    /// and the service writes directly, so a single `DatabaseQueue` would have them racing over a
    /// project each believes it owns. What has to match is the state a command *sees*, and that is
    /// arranged by driving the same commands through both.
    private struct ParityHosts {
        let window: AppControlHost
        let headless: MimicControlService
        /// Held because `AppControlHost` holds the session *weakly*, so nothing else here keeps it
        /// alive. Drop this and every command against the window answers "The Mimic session is no
        /// longer available." — a suite that would look like a broken host rather than a freed one.
        let appState: AppState
        /// The engine behind the window's runtime, so a lifecycle test can assert what the runtime
        /// actually asked it to do rather than what the host said about it. A host sentence cannot
        /// see a command dropped on the way to the engine, which is the whole of the defect
        /// ``serverLifecycleReportsWhatTheRuntimeDid`` covers.
        let engine: ParityStubEngine
    }

    private struct ParityResponses {
        let window: ControlResponse
        let headless: ControlResponse
    }

    /// An engine that serves nothing and reports no journey.
    ///
    /// Every command this suite drives is one that needs neither a bound port nor served traffic, and
    /// the window's host reaches the engine only through `MockServerRuntime`. A stub keeps the app
    /// side deterministic and keeps a parity run from opening a socket.
    private actor ParityStubEngine: MockServerEngineProtocol {
        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation

        /// What the runtime actually asked of the engine, which is the only witness a lifecycle test
        /// has. A dropped command and an executed one produce the same reply from a host that answers
        /// with a fixed sentence — and one of them did.
        private(set) var startedPorts: [Int] = []
        private(set) var stopCount = 0

        /// Holds `start` open, so `.starting` is a state a test can stand in rather than a window it
        /// has to race.
        ///
        /// Without it, the interval between `startServer()` publishing `.starting` and the engine
        /// binding is decided by the scheduler: the stop under test would sometimes arrive at
        /// `.running` instead, and pass for the wrong reason. Sleeping rather than spinning, so the
        /// actor is handed back on every suspension and the counters above stay readable while a
        /// start is parked here — the shape `MockServerRuntimeTests.GatedEngine` already uses.
        private var isHoldingStart = false

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func holdStart() { isHoldingStart = true }

        func releaseStart() { isHoldingStart = false }

        func start(configuration: ServerConfiguration) async throws {
            // Nothing binds a port here; the runtime only needs the call to return — eventually.
            startedPorts.append(configuration.port)
            while isHoldingStart {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        func stop() async throws { stopCount += 1 }

        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {}
    }

    private func makeHosts() throws -> ParityHosts {
        let headlessQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let headless = MimicControlService(
            repository: GRDBProjectRepository(dbQueue: headlessQueue),
            settings: SettingsStore(dbQueue: headlessQueue),
            engine: MockServerEngine(),
            // The window's host derives its mode from the process environment. Hard-coding
            // `"headless"` here would make `state` disagree about `mode` for a reason that has
            // nothing to do with either host, and the suite would be reporting on its own fixture.
            mode: HeadlessMode.isEnabled ? "headless" : "app"
        )

        let windowQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        // Its own defaults suite, so a run cannot inherit — or overwrite — a real recents list or a
        // real window arrangement. `PanelLayoutStore()` would bind to `.standard` and do exactly that.
        let defaults = try #require(UserDefaults(suiteName: "HostParityTests.\(UUID().uuidString)"))
        let engine = ParityStubEngine()
        let appState = AppState(
            server: MockServerRuntime(engine: engine),
            projectRepository: GRDBProjectRepository(dbQueue: windowQueue),
            recentProjectsStore: RecentProjectsStore(defaults: defaults),
            panelLayoutStore: PanelLayoutStore(defaults: defaults)
        )

        return ParityHosts(
            window: AppControlHost(appState: appState, repository: appState.repository),
            headless: headless,
            appState: appState,
            engine: engine
        )
    }

    /// Polls `predicate` until it holds or the timeout elapses.
    ///
    /// The lifecycle test below waits on work the runtime dispatched to a task of its own —
    /// `engine.start` and `engine.stop` are both reached that way — and a fixed sleep would be either
    /// flaky or slow. Private and duplicated from `MockServerRuntimeTests` because a test target is a
    /// module and neither suite exports its helpers.
    private func waitUntil(
        timeout: Duration = .seconds(2),
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

    /// The same poll for a predicate that has to ask an actor. Named apart from ``waitUntil(timeout:interval:_:)``
    /// rather than overloaded on the closure's effects, which is the shape that resolves to whichever
    /// overload the compiler happens to prefer — `MockServerRuntimeTests` keeps the pair for the same
    /// reason.
    private func waitUntilAsync(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(20),
        _ predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: interval)
        }
        Issue.record("Timed out waiting for condition")
    }

    /// Opens the same project on both hosts, through the command surface rather than around it.
    ///
    /// `projectCreate` is one of the declared contract differences — the window answers optimistically
    /// — but it opens the project synchronously on both sides, which is what the rest of the suite
    /// needs. A seed that failed would make every downstream assertion meaningless, so both replies
    /// are required to carry a result.
    private func seedProject(
        _ hosts: ParityHosts,
        name: String = "Checkout",
        port: Int = 9099
    ) async throws {
        let responses = await run(.projectCreate(name: name, port: port), on: hosts)
        _ = try #require(responses.window.result, "the window's host did not open the seed project")
        _ = try #require(responses.headless.result, "the headless service did not open the seed project")
    }

    // MARK: - Comparison

    private func run(_ command: ControlCommand, on hosts: ParityHosts) async -> ParityResponses {
        ParityResponses(
            window: await hosts.window.execute(command),
            headless: await hosts.headless.execute(command)
        )
    }

    /// Runs `command` against both hosts and requires the answers to agree in the ways that matter.
    @discardableResult
    private func expectParity(
        _ command: ControlCommand,
        on hosts: ParityHosts,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> ParityResponses {
        let responses = await run(command, on: hosts)
        let name = command.kind.rawValue
        // Built into locals first: `#expect`'s comment parameter is a `Comment`, which a string
        // *literal* converts to and a `String` expression does not.
        let windowSays = responses.window.error?.message ?? responses.window.result?.message ?? "—"
        let headlessSays = responses.headless.error?.message ?? responses.headless.result?.message ?? "—"
        let okSummary = "window \(responses.window.ok) (\(windowSays)), "
            + "headless \(responses.headless.ok) (\(headlessSays))"
        let codeSummary = "window \(responses.window.error?.code ?? "none"), "
            + "headless \(responses.headless.error?.code ?? "none")"

        #expect(
            responses.window.ok == responses.headless.ok,
            "\(name) succeeded on one host and failed on the other: \(okSummary)",
            sourceLocation: sourceLocation
        )
        #expect(
            responses.window.error?.code == responses.headless.error?.code,
            "\(name) failed with different codes: \(codeSummary)",
            sourceLocation: sourceLocation
        )

        let windowFields = try Self.populatedFields(responses.window.result)
        let headlessFields = try Self.populatedFields(responses.headless.result)
        #expect(
            windowFields == headlessFields,
            "\(name): window populated \(windowFields.sorted()), headless \(headlessFields.sorted())",
            sourceLocation: sourceLocation
        )

        // …and what is *in* those fields, which the check above cannot see. Kept as a second
        // assertion rather than folded into it because the key-set message is the readable one when
        // a field goes missing, and this one is the readable one when a value goes wrong.
        let allowed = Self.allowedDifferingFields(for: command.kind)
        let windowValues = try Self.comparableJSON(responses.window.result, allowing: allowed)
        let headlessValues = try Self.comparableJSON(responses.headless.result, allowing: allowed)
        let valueSummary = "\(name) answered with different values.\n"
            + "  window:   \(windowValues)\n"
            + "  headless: \(headlessValues)\n"
            + "  allowed to differ: \(allowed.sorted())"
        #expect(
            windowValues == headlessValues,
            "\(valueSummary)",
            sourceLocation: sourceLocation
        )

        return responses
    }

    /// The result fields a caller can actually see, taken from the wire rather than from a hand-kept
    /// list of properties.
    ///
    /// `ControlResult`'s synthesized encoder omits `nil` optionals entirely, so the JSON keys *are*
    /// the populated fields — and a field added to `ControlResult` later is compared without anybody
    /// remembering to add it here.
    private static func populatedFields(_ result: ControlResult?) throws -> Set<String> {
        guard let result else { return [] }
        let data = try ControlCoding.encoder().encode(result)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return Set(object.keys)
    }

    // MARK: - What two hosts are allowed to answer differently

    /// One result field the two hosts may legitimately disagree about, and why.
    ///
    /// Written as data rather than as a `guard` inside each test, so the exceptions are enumerable:
    /// an allowance nobody can list is indistinguishable from an assertion nobody wrote.
    private struct AllowedDifference {
        /// The JSON key, matched wherever it appears in the encoded result — `pid` and `appVersion`
        /// sit inside `state`, `modifiedAt` inside `project` and inside every entry of `projects`.
        let field: String
        let reason: String
    }

    /// Allowed for every command, because they describe *when* an answer was produced rather than
    /// what it says.
    ///
    /// Each of these is a wall-clock instant stamped independently by two hosts that did the same
    /// work microseconds apart. Requiring them to match would be requiring the two to run in the same
    /// instant, which is not a contract anything can keep.
    private static let universalAllowances: [AllowedDifference] = [
        AllowedDifference(
            field: "createdAt",
            reason: "Each host builds its own `MockProject`, so the two are created a moment apart."
        ),
        AllowedDifference(
            field: "modifiedAt",
            reason: """
            Stamped with `Date()` by whichever host applied the mutation, and by the store underneath \
            it. Two hosts mutating the same document in sequence cannot land on one instant.
            """
        ),
        AllowedDifference(
            field: "timestamp",
            reason: "A `RequestLog` records when the request was served; two engines serve at two instants."
        ),
    ]

    /// Allowed for one command, with the reason that command in particular may differ.
    ///
    /// Deliberately short. Every entry is a place this suite has stopped being able to see a
    /// divergence, so adding one is a cost and not a convenience: the reasons here are either an
    /// artefact of running two hosts in a single test process (`pid`, and the `ping` sentence that
    /// embeds it), an artefact of the stub engine the window is given (`journeyAdvance`), or a
    /// contract difference already written down in ``contractDifferences`` (`projectImport`'s tense).
    /// Nothing is listed because it was easier than fixing it.
    private static let allowancesByCommand: [CommandKind: [AllowedDifference]] = [
        .ping: [
            AllowedDifference(
                field: "message",
                reason: """
                The sentence carries this instance's pid and mode. They match here only because one \
                test process is hosting both hosts; two real instances are two processes, so pinning \
                the sentence would pin the fixture. Same reason as `pid` under `state` below.
                """
            ),
        ],
        .state: [
            AllowedDifference(
                field: "pid",
                reason: """
                Two instances are two processes. This fixture runs both hosts inside one, so the two \
                agree here for a reason that has nothing to do with either host.
                """
            ),
            AllowedDifference(
                field: "appVersion",
                reason: """
                The window reads `Bundle.main`; the service is told, and this fixture tells it \
                nothing. That is a difference in what each instance *is*, not in how it answers — and \
                it is a difference in presence as well as value, which is why allowed fields are \
                dropped rather than blanked.
                """
            ),
        ],
        .reset: [
            AllowedDifference(field: "pid", reason: "`reset` carries a `state`; see `.state` above."),
            AllowedDifference(field: "appVersion", reason: "`reset` carries a `state`; see `.state` above."),
        ],
        .projectImport: [
            AllowedDifference(
                field: "message",
                reason: """
                A declared contract difference: "Importing project …" from the window, whose save is a \
                detached task, and "Imported project …" from the service, whose save is awaited. The \
                `project` field — the part a caller reads — is compared and must match.
                """
            ),
        ],
        .journeyAdvance: [
            AllowedDifference(
                field: "message",
                reason: """
                The service names the position it advanced to; the window does not. Both sentences are \
                built from a cursor, and this fixture's window engine has none — see the field below.
                """
            ),
            AllowedDifference(
                field: "journeyStatus",
                reason: """
                A fixture limit, not a contract one. `ParityStubEngine` takes the protocol's default \
                `advanceJourney()`, which reports no cursor, so the window answers from its \
                not-yet-started fallback while the service answers from a real engine that moved. \
                That the window reports the *engine's* answer is asserted where an engine can be made \
                to answer: `AppStateAndViewTests.controlHostAdvanceReportsTheEngineAnswer`.
                """
            ),
        ],
    ]

    private static func allowedDifferingFields(for kind: CommandKind) -> Set<String> {
        Set((universalAllowances + (allowancesByCommand[kind] ?? [])).map(\.field))
    }

    /// The encoded result with the allowed fields removed and minted UUIDs blanked, as a string two
    /// hosts' answers can be compared by.
    ///
    /// Allowed fields are **removed** rather than blanked, because an allowance has to cover presence
    /// as well as value: `appVersion` is `nil` on the service in this fixture and non-`nil` on the
    /// window, so a blanked value would still leave one object carrying a key the other does not.
    /// Everything else keeps its key, so a field appearing on one side alone still fails.
    private static func comparableJSON(
        _ result: ControlResult?,
        allowing allowed: Set<String>
    ) throws -> String {
        guard let result else { return "(no result)" }
        let data = try ControlCoding.encoder().encode(result)
        let decoded = try JSONSerialization.jsonObject(with: data)
        let normalised = normalise(decoded, allowing: allowed)
        let encoded = try JSONSerialization.data(
            withJSONObject: normalised,
            options: [.sortedKeys, .fragmentsAllowed]
        )
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func normalise(_ value: Any, allowing allowed: Set<String>) -> Any {
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, nested) in object where !allowed.contains(key) {
                if isMintedIdentifier(key: key, value: nested) {
                    result[key] = "<minted uuid>"
                } else {
                    result[key] = normalise(nested, allowing: allowed)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { normalise($0, allowing: allowed) }
        }
        return value
    }

    /// Whether this key holds a UUID each host minted for itself.
    ///
    /// Every id in a result graph is one: the two hosts create their own project, so its id, its
    /// endpoints', its scenarios', its journeys' and its steps' are all independently generated and
    /// can never match. The value is checked as well as the key name on purpose —
    /// `JourneyTemplates.Template.id` is a stable kebab-case handle, not a UUID, and it stays
    /// compared. The key keeps its place with a placeholder, so an id present on one side and absent
    /// on the other (a dangling `activeJourneyID`, say) still fails.
    private static func isMintedIdentifier(key: String, value: Any) -> Bool {
        guard key == "id" || key.hasSuffix("ID") else { return false }
        guard let text = value as? String else { return false }
        return UUID(uuidString: text) != nil
    }

    /// An allowance describes a real field and carries a real reason.
    ///
    /// Cheap, and it is the check that stops the list becoming a place to make a failure go away:
    /// a blank reason, or a duplicate entry quietly added beside an existing one, is how an
    /// exceptions table turns into a suppression table.
    @Test("Every allowed difference names a field once and says why")
    func allowedDifferencesAreJustified() {
        var lists: [String: [AllowedDifference]] = ["(universal)": Self.universalAllowances]
        for (kind, allowances) in Self.allowancesByCommand {
            lists[kind.rawValue] = allowances
        }
        for (owner, allowances) in lists {
            let fields = allowances.map(\.field)
            #expect(
                Set(fields).count == fields.count,
                "\(owner) lists a field twice: \(fields.sorted())"
            )
            for allowance in allowances {
                #expect(
                    allowance.reason.count > 20,
                    "\(owner).\(allowance.field) is allowed to differ with no reason given"
                )
            }
        }
        // Universal allowances are applied to every command, so repeating one per command is a sign
        // somebody stopped reading the list before adding to it.
        let universal = Set(Self.universalAllowances.map(\.field))
        for (kind, allowances) in Self.allowancesByCommand {
            let repeated = Set(allowances.map(\.field)).intersection(universal)
            #expect(
                repeated.isEmpty,
                "\(kind.rawValue) repeats an already-universal allowance: \(repeated.sorted())"
            )
        }
    }

    // MARK: - Routing: every kind reaches an implementation

    /// One payload per ``CommandKind``, in a switch with **no `default`**.
    ///
    /// That is the whole point of writing it out rather than importing a list: adding a `CommandKind`
    /// stops this file compiling until somebody supplies a sample, so the two sweeps below cannot
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

    /// The code both hosts answer with from the arm that means "nothing here handles this command".
    ///
    /// `AppControlHost.perform` and `MimicControlService.run` each end in a `default:` that reports
    /// exactly that, and both build it with `ControlError.internalFailure` — so this is read from the
    /// constructor rather than written out, and cannot drift from it.
    ///
    /// It is `internalFailure`'s *general* code, which each host also uses for an unexpected error it
    /// could not classify. So a failure here could in principle be one of those instead. That is why
    /// every assertion below prints the message: `"… is host-scoped but the app's control host does
    /// not implement it."` is unmistakable, and anything else in that slot is a different bug worth
    /// reading rather than a false alarm worth suppressing.
    static let unimplementedCommandCode = ControlError.internalFailure("").code

    /// The gap `HostParityTests` was one test short of closing.
    ///
    /// Every other case here compares two hosts on commands somebody chose to list. So a *new*
    /// host-scoped command, implemented in neither host, compiled clean, passed the whole suite, and
    /// surfaced at runtime as `internal.failure` — after `mimic commands` had already advertised it to
    /// whatever was driving the instance. Nothing in three test targets looked at the two `default:`
    /// arms that produce it.
    ///
    /// Driven with **no project open**, which is the state that makes the sweep safe as well as
    /// complete: every host-scoped arm is reached, and the ones that need a document refuse with
    /// `project.noneOpen` before they can touch a store, a socket or an engine. `serverStart` is the
    /// case that makes this matter — the headless service holds a real `MockServerEngine`, and with a
    /// project open it would bind a real port, which is why the seeded pass below skips it.
    @Test("Every host-scoped command is answered by both hosts, not left to the unimplemented arm")
    func everyHostScopedCommandIsRoutedByBothHosts() async throws {
        for kind in CommandKind.allCases where kind.scope == .host {
            let hosts = try makeHosts()
            let responses = await run(Self.sample(for: kind), on: hosts)

            #expect(
                responses.window.error?.code != Self.unimplementedCommandCode,
                "\(kind.rawValue): the window's host has no arm for it — \(responses.window.error?.message ?? "")"
            )
            #expect(
                responses.headless.error?.code != Self.unimplementedCommandCode,
                "\(kind.rawValue): the headless service has no arm for it — \(responses.headless.error?.message ?? "")"
            )
        }
    }

    /// The same sweep once a project is open, because "no project is open" is a legitimate answer and
    /// a command that only ever produced it would pass the pass above without ever reaching its own
    /// arm.
    ///
    /// `serverStart` is skipped and only `serverStart`: the headless service's engine is a real
    /// `MockServerEngine`, so with a project open this would put a listener on port 9099 and a parity
    /// suite has no business opening sockets. It is covered without a project by the sweep above,
    /// where both hosts refuse it before the engine is touched, and its contract difference is
    /// recorded in ``contractDifferences``.
    @Test("Every host-scoped command reaches its own arm with a project open")
    func everyHostScopedCommandIsRoutedWithAProjectOpen() async throws {
        for kind in CommandKind.allCases where kind.scope == .host {
            guard kind != .serverStart else { continue }

            let hosts = try makeHosts()
            try await seedProject(hosts)
            let responses = await run(Self.sample(for: kind), on: hosts)

            #expect(
                responses.window.error?.code != Self.unimplementedCommandCode,
                "\(kind.rawValue): the window's host has no arm for it — \(responses.window.error?.message ?? "")"
            )
            #expect(
                responses.headless.error?.code != Self.unimplementedCommandCode,
                "\(kind.rawValue): the headless service has no arm for it — \(responses.headless.error?.message ?? "")"
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

    // MARK: - Agreement, with nothing open

    /// The state a script meets first: an instance that has been reached but has no project yet.
    @Test(
        "Both hosts answer identically with no project open",
        arguments: [
            ControlCommand.ping,
            .describeCommands,
            .state,
            .projectList,
            .projectExport(project: nil),
            .projectCreate(name: "   ", port: nil),
            .serverStatus,
            .serverStop,
            .serverStart(port: nil),
            .logList(limit: nil, unmatchedOnly: nil),
            .logClear,
            .reset(scope: .all),
            .reset(scope: .journey),
            .endpointList,
            .journeyList,
            .journeyStatus,
            .journeyRestart,
            .journeyAdvance,
            .journeyActivate(journey: nil),
            .projectRename(name: "Renamed"),
            .serverConfigure(port: 9000, globalDelayMs: nil),
        ]
    )
    func hostsAgreeWithNoProjectOpen(command: ControlCommand) async throws {
        let hosts = try makeHosts()
        try await expectParity(command, on: hosts)
    }

    // MARK: - Agreement, with a project open

    /// The same surface once a project exists. The project-scoped entries are here on purpose: they
    /// are answered by `ProjectCommandExecutor` for both hosts, so they are the control group — if one
    /// of these ever disagrees, the seam itself has come apart rather than a host having drifted.
    @Test(
        "Both hosts answer identically with a project open",
        arguments: [
            ControlCommand.state,
            .serverStatus,
            .serverConfigure(port: 9222, globalDelayMs: 125),
            .serverConfigure(port: nil, globalDelayMs: nil),
            .projectRename(name: "Renamed"),
            .projectRename(name: ""),
            .projectExport(project: nil),
            .endpointList,
            .endpointCreate(name: "Login", method: .post, path: "/login", spec: nil),
            .endpointCreate(name: "Bad", method: .get, path: "no-leading-slash", spec: nil),
            .endpointGet(endpoint: .route(.get, "/missing")),
            .endpointDelete(endpoint: .name("nope")),
            .journeyList,
            .journeyTemplateList,
            .journeyAddTemplate(templateID: "payment-retry", name: "Flow"),
            .journeyAddTemplate(templateID: "no-such-template", name: nil),
            .journeyActivate(journey: .name("nope")),
            .journeyActivate(journey: nil),
            .journeyStatus,
            .journeyRestart,
            .journeyAdvance,
            .logList(limit: 5, unmatchedOnly: true),
            .logClear,
            .reset(scope: .all),
            .reset(scope: .logs),
            .reset(scope: .journey),
        ]
    )
    func hostsAgreeWithAProjectOpen(command: ControlCommand) async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)
        try await expectParity(command, on: hosts)
    }

    /// An imported document is the one way into a project that skips the per-field validators, so both
    /// hosts run `ProjectValidator` before anything is stored. They refuse the same document with the
    /// same code — and, because the sentence is built by `ControlError.validation` in Domain rather
    /// than by either host, with the same message.
    @Test("Both hosts refuse an invalid document before storing it")
    func hostsAgreeOnAnInvalidImport() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)

        let broken = MockProject(
            name: "Broken",
            serverConfiguration: ServerConfiguration(port: 70_000, globalDelayMs: 0)
        )
        let responses = try await expectParity(
            .projectImport(project: broken, activate: false),
            on: hosts
        )

        #expect(responses.window.error?.code == "request.invalid")
        #expect(responses.window.error?.message == responses.headless.error?.message)
    }

    /// `reset` is the one reply both hosts build in the same place, so it is the one whose wording is
    /// worth pinning. It reported `Reset all.` from the window and `Reset 12 log entries and journey
    /// "Checkout"` from the service until `ControlMessages` was introduced; this is what stops that
    /// happening again.
    @Test("Reset reports what it cleared, in the same words, from both hosts")
    func resetSaysTheSameThing() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)

        let idle = try await expectParity(.reset(scope: .all), on: hosts)
        #expect(idle.window.result?.message == idle.headless.result?.message)
        #expect(idle.window.result?.message == "Reset 0 log entries.")

        // A scope whose every target reports nothing back is the other half of the sentence.
        let nothing = try await expectParity(.reset(scope: .journey), on: hosts)
        #expect(nothing.window.result?.message == nothing.headless.result?.message)
        #expect(nothing.window.result?.message == "Nothing to reset.")

        try await expectParity(.journeyAddTemplate(templateID: "payment-retry", name: "Flow"), on: hosts)
        try await expectParity(.journeyActivate(journey: .name("Flow")), on: hosts)

        // The window reads the journey it is about to rewind from the session; the service reads the
        // name back off the engine's cursor. Two different routes to the same sentence.
        let running = try await expectParity(.reset(scope: .journey), on: hosts)
        #expect(running.window.result?.message == running.headless.result?.message)
        #expect(running.window.result?.message == "Reset journey \"Flow\".")
    }

    /// A whole script, in order, rather than one command against a fresh instance — because a host
    /// that answers every command correctly in isolation can still lose track of what it has been
    /// asked to do.
    @Test("A scripted flow gets the same answers from both hosts at every step")
    func aScriptedFlowAgreesAtEveryStep() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)

        // The configuration a command writes has to be the configuration the next command reads. The
        // window's host once kept a second copy on the runtime, so `server configure` reached the
        // project and `server status` reported the runtime — this is that bug's parity check.
        try await expectParity(.serverConfigure(port: 9222, globalDelayMs: 125), on: hosts)
        let status = try await expectParity(.serverStatus, on: hosts)
        #expect(status.window.result?.server?.port == 9222)
        #expect(status.window.result?.server?.port == status.headless.result?.server?.port)
        #expect(
            status.window.result?.server?.globalDelayMs
                == status.headless.result?.server?.globalDelayMs
        )

        let created = try await expectParity(
            .endpointCreate(name: "Login", method: .post, path: "/login", spec: nil),
            on: hosts
        )
        #expect(created.window.result?.endpoint?.path == created.headless.result?.endpoint?.path)

        let template = try await expectParity(
            .journeyAddTemplate(templateID: "payment-retry", name: "Flow"),
            on: hosts
        )
        #expect(
            template.window.result?.journey?.steps.count
                == template.headless.result?.journey?.steps.count
        )

        // Activating always begins a clean run on both: the window resets the cursor by applying the
        // project to the engine, the service by pushing its configuration.
        let activated = try await expectParity(.journeyActivate(journey: .name("Flow")), on: hosts)
        #expect(activated.window.result?.journeyStatus?.currentStepIndex == 0)
        #expect(
            activated.window.result?.journeyStatus?.currentStepIndex
                == activated.headless.result?.journeyStatus?.currentStepIndex
        )
        #expect(
            activated.window.result?.journeyStatus?.totalSteps
                == activated.headless.result?.journeyStatus?.totalSteps
        )

        let reported = try await expectParity(.journeyStatus, on: hosts)
        #expect(
            reported.window.result?.journeyStatus?.totalSteps
                == reported.headless.result?.journeyStatus?.totalSteps
        )

        // `state` is the command a caller polls after every optimistic reply, so the counts it carries
        // are the ones a script actually depends on. `expectParity` already compares all of this by
        // value — `appVersion` and `pid` excepted, for the reasons in `allowancesByCommand` — and the
        // field-by-field expectations are kept because they name what failed instead of printing two
        // JSON documents to diff by eye.
        let state = try await expectParity(.state, on: hosts)
        let windowState = try #require(state.window.result?.state)
        let headlessState = try #require(state.headless.result?.state)
        #expect(windowState.mode == headlessState.mode)
        #expect(windowState.apiVersion == headlessState.apiVersion)
        #expect(windowState.project?.name == headlessState.project?.name)
        #expect(windowState.endpointCount == headlessState.endpointCount)
        #expect(windowState.journeyCount == headlessState.journeyCount)
        #expect(windowState.requestLogCount == headlessState.requestLogCount)
        #expect(windowState.activeJourney?.journeyName == headlessState.activeJourney?.journeyName)
    }

    // MARK: - Consolidated into Domain

    /// A host-scoped answer that is no longer written twice, and what moved.
    ///
    /// **This table is the difference between two kinds of parity, and the distinction matters when
    /// reading a green run of this suite.** Everything else here is parity *by test*: two
    /// implementations exist, they are driven side by side, and the run says they agreed today. The
    /// entries below are parity *by construction*: there is one implementation, in Domain, and both
    /// hosts call it — so the only way they can disagree is for somebody to stop calling it, which is
    /// what ``consolidatedRepliesComeFromDomain()`` is for. It compares each reply against the value
    /// Domain produces rather than against the other host, because two hosts that have both inlined
    /// the same wrong sentence agree perfectly.
    ///
    /// Still parity by test only — two implementations, held together by this file:
    ///
    /// - `projectCreate`, `projectOpen`, `projectClose`, `projectDelete`, `projectDuplicate`,
    ///   `projectExport`, `projectImport`, `projectList` — the window initiates through `AppState`
    ///   and the service awaits a repository. Five of them are declared contract differences below.
    /// - `serverStart` and `serverStop`'s success sentences — one reports intent, the other a bind.
    /// - `journeyAdvance`'s sentence — the service names the position it reached.
    /// - `state` and `serverStatus`'s *inputs* — which project is open, what the engine is doing.
    ///   The shaping is shared; reading the state is not, and cannot be.
    ///
    /// One helper moved to Domain that only the window reaches: `MockProject.matches`, the
    /// open-project shortcut. The service has no equivalent — it saves before it answers, so the
    /// store is never behind it — so that is a consolidation of the window's own two copies rather
    /// than of a cross-host pair. `DomainTests.ProjectReferenceTests` covers it, including that it
    /// and `requireNamed` pick the same project.
    private struct SharedImplementation {
        let kind: CommandKind
        /// What is now built in Domain rather than in each host.
        let shared: String
    }

    private static let sharedByConstruction: [SharedImplementation] = [
        SharedImplementation(kind: .ping, shared: "ControlMessages.ping(mode:pid:)"),
        SharedImplementation(kind: .state, shared: "HostReport.state — the summary and both counts"),
        SharedImplementation(kind: .reset, shared: "ControlMessages.reset, and the state it carries"),
        SharedImplementation(
            kind: .serverStatus,
            shared: "HostReport.serverStatus — the state string, the loopback baseURL, the message"
        ),
        SharedImplementation(
            kind: .serverStart,
            shared: "ControlMessages.serverAlreadyRunning(port:), ControlError.serverBusy"
        ),
        SharedImplementation(
            kind: .serverStop,
            shared: "ControlMessages.serverNotRunning, ControlError.serverBusy"
        ),
        SharedImplementation(
            kind: .journeyActivate,
            shared: "ControlMessages.journeyActivated(name:stepCount:) and .journeyCleared"
        ),
        SharedImplementation(kind: .journeyRestart, shared: "ControlMessages.journeyRestarted(name:)"),
        SharedImplementation(kind: .logList, shared: "HostReport.requestLog — filter, trim, redaction"),
        SharedImplementation(kind: .logClear, shared: "ControlMessages.logCleared(count:)"),
        SharedImplementation(kind: .projectList, shared: "HostReport.projectSummaries — the count merge"),
        SharedImplementation(
            kind: .projectImport,
            shared: "ControlMessages.projectImporting/projectImported — one sentence, two verbs"
        ),
        SharedImplementation(
            kind: .projectCreate,
            shared: "ControlError.emptyProjectName, String.nilIfEmpty"
        ),
        SharedImplementation(
            kind: .projectExport,
            shared: "MockProject.requireNamed — the by-name store lookup"
        ),
        SharedImplementation(
            kind: .projectOpen,
            shared: "MockProject.requireNamed — the by-name store lookup"
        ),
        SharedImplementation(
            kind: .projectDelete,
            shared: "MockProject.requireNamed — the by-name store lookup"
        ),
        SharedImplementation(
            kind: .projectDuplicate,
            shared: "MockProject.requireNamed — the by-name store lookup"
        ),
    ]

    /// The table above can only ever name host-scoped commands, for the mirror of the reason
    /// ``contractDifferences`` can: a project-scoped command was *already* one implementation, so
    /// listing one here would be claiming credit for `ProjectCommandExecutor`.
    @Test("Only host-scoped commands are listed as newly consolidated")
    func sharedImplementationsNameOnlyHostScopedCommands() {
        for entry in Self.sharedByConstruction {
            #expect(
                entry.kind.scope == .host,
                "\(entry.kind.rawValue) is project-scoped: it was never implemented twice"
            )
            #expect(
                entry.shared.count > 10,
                "\(entry.kind.rawValue) is listed as consolidated without saying what moved"
            )
        }
        let kinds = Self.sharedByConstruction.map(\.kind)
        #expect(Set(kinds).count == kinds.count, "A command is listed twice in sharedByConstruction.")
    }

    /// The consolidation, driven: each reply is required to equal what Domain builds, not merely what
    /// the other host said.
    ///
    /// Comparing the two hosts is what the rest of this suite does, and it cannot see a sentence both
    /// of them have inlined identically — which is precisely how `logClear`'s pluralisation and the
    /// server lifecycle sentences came to exist in two files. Reading the expectation out of
    /// `ControlMessages` and `HostReport` instead means the assertion fails the moment either host
    /// stops calling the shared code, whatever it starts saying instead.
    @Test("Replies consolidated into Domain are answered from Domain, by both hosts")
    func consolidatedRepliesComeFromDomain() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts, name: "Checkout", port: 9099)

        // `ping` is the one sentence `expectParity` is not allowed to compare — it carries this
        // instance's pid — so before the consolidation nothing in any suite looked at it at all. It
        // is built once now, which makes it checkable against the builder.
        let expectedPing = ControlMessages.ping(
            mode: HeadlessMode.isEnabled ? "headless" : "app",
            pid: Int(ProcessInfo.processInfo.processIdentifier)
        )
        let pinged = try await expectParity(.ping, on: hosts)
        #expect(pinged.window.result?.message == expectedPing)
        #expect(pinged.headless.result?.message == expectedPing)

        // The pluralising sentence that lived in both hosts. The singular/plural itself is pinned in
        // `DomainTests.ControlMessagesTests`; what is pinned here is that both hosts ask for it.
        let cleared = try await expectParity(.logClear, on: hosts)
        #expect(cleared.window.result?.message == ControlMessages.logCleared(count: 0))

        // The status switch — twenty-eight identical lines in each host. Built from the report's own
        // port and delay, so what this pins is the shaping: the state string, the absence of a
        // `baseURL` while nothing is bound, and the absence of a message.
        let status = try await expectParity(.serverStatus, on: hosts)
        let report = try #require(status.window.result?.server)
        #expect(report == HostReport.serverStatus(
            state: .stopped,
            configuredPort: report.port,
            globalDelayMs: report.globalDelayMs
        ))
        #expect(report.port == 9099, "the seeded project's port is not what `server status` reports")

        // Nothing is bound, so a stop is the shared "nothing to do" sentence from both.
        let idle = try await expectParity(.serverStop, on: hosts)
        #expect(idle.window.result?.message == ControlMessages.serverNotRunning)

        // Journey activation, both halves.
        let added = try await expectParity(
            .journeyAddTemplate(templateID: "payment-retry", name: "Flow"),
            on: hosts
        )
        let stepCount = try #require(added.window.result?.journey?.steps.count)
        let activated = try await expectParity(.journeyActivate(journey: .name("Flow")), on: hosts)
        #expect(
            activated.window.result?.message
                == ControlMessages.journeyActivated(name: "Flow", stepCount: stepCount)
        )

        // `run` rather than `expectParity`, and deliberately: the service reports the *engine's*
        // restarted cursor while the window reports the journey as not-yet-started, and comparing a
        // real engine against `ParityStubEngine` is the fixture limit already recorded for
        // `journeyAdvance`. The sentence is the part that was written twice, and it is the part
        // checked here — against Domain, from both.
        let restarted = await run(.journeyRestart, on: hosts)
        #expect(restarted.window.ok)
        #expect(restarted.headless.ok)
        #expect(restarted.window.result?.message == ControlMessages.journeyRestarted(name: "Flow"))
        #expect(restarted.headless.result?.message == ControlMessages.journeyRestarted(name: "Flow"))

        let deactivated = try await expectParity(.journeyActivate(journey: nil), on: hosts)
        #expect(deactivated.window.result?.message == ControlMessages.journeyCleared)
    }

    /// The half of the import sentence that is *not* a contract difference.
    ///
    /// `projectImportDiffersInTenseOnly` below checks the verbs. This checks the claim the two
    /// functions in `ControlMessages` exist to make: everything after the verb is one sentence, so
    /// the counted tail cannot drift on one host while the other keeps the old wording — which is a
    /// difference `expectParity` would never see, since `message` is an allowed difference for this
    /// command precisely because of the verb.
    @Test("Import says the same thing after the verb from both hosts")
    func importSentencesDifferOnlyInTheirVerb() async throws {
        let hosts = try makeHosts()
        var document = MockProject(name: "Fixture")
        _ = try ProjectCommandExecutor.apply(
            .endpointCreate(name: "Login", method: .post, path: "/login", spec: nil),
            to: &document
        )

        let responses = try await expectParity(
            .projectImport(project: document, activate: false),
            on: hosts
        )

        let window = try #require(responses.window.result?.message)
        let headless = try #require(responses.headless.result?.message)
        #expect(window == ControlMessages.projectImporting(name: "Fixture", endpointCount: 1, journeyCount: 0))
        #expect(headless == ControlMessages.projectImported(name: "Fixture", endpointCount: 1, journeyCount: 0))
        // Same sentence, one verb apart. "Importing" is a character longer than "Imported", which is
        // the whole of the difference the two hosts are allowed.
        #expect(window.dropFirst("Importing".count) == headless.dropFirst("Imported".count))
    }

    // MARK: - Declared contract differences

    /// A difference that is contract rather than drift, with the reason it is allowed to exist.
    ///
    /// Written down rather than silently skipped: an exception nobody records is indistinguishable
    /// from a defect nobody noticed, and the point of listing them is that the tests below pin the
    /// current answers — so if one of these ever changes, this suite notices and somebody has to
    /// decide whether the change was intended.
    private struct ContractDifference {
        let kind: CommandKind
        /// What the window's host answers.
        let window: String
        /// What the headless service answers.
        let headless: String
        /// Why the two are allowed to differ.
        let reason: String
    }

    private static let contractDifferences: [ContractDifference] = [
        ContractDifference(
            kind: .projectCreate,
            window: #"ok, "Creating and opening project "X"." and no project field"#,
            headless: #"ok, "Created and opened project "X"." with the project"#,
            reason: """
            The window's store access is asynchronous — autosave, recents and GRDB all sit behind it — \
            and a control call has to answer now, so the command is initiated and the caller confirms \
            with `state`. The service awaits its own repository and can report what it stored.
            """
        ),
        ContractDifference(
            kind: .projectOpen,
            window: #"ok, "Opening project." and no project field"#,
            headless: #"ok, "Opened project "X"." with the project"#,
            reason: "Same asynchronous store access as projectCreate."
        ),
        ContractDifference(
            kind: .projectDuplicate,
            window: #"ok, "Duplicating the project." and no project field"#,
            headless: #"ok, "Duplicated project as "X (Copy)"." with the copy"#,
            reason: "Same asynchronous store access as projectCreate."
        ),
        ContractDifference(
            kind: .projectDelete,
            window: #"ok, "Deleted the project.""#,
            headless: #"ok, "Deleted project "X".""#,
            reason: """
            The window hands the delete to the session and answers; the service awaits the store and \
            has the name it removed. Only the *tense* differs now: the sentence this row used to end \
            with — that an id naming nothing is accepted rather than refused, because the window never \
            waits — stopped being true when the window started resolving the reference against the \
            store before answering. See `anUnknownProjectIDIsRefusedByBothHosts`.
            """
        ),
        ContractDifference(
            kind: .projectImport,
            window: #"ok, "Importing project "X" (n endpoints, n journeys)." with the document"#,
            headless: #"ok, "Imported project "X" (n endpoints, n journeys)." with the document"#,
            reason: """
            Both validate the whole document first and both hand the document back, so only the tense \
            differs: the window's save is a detached task, the service's is awaited.
            """
        ),
        // `projectList` was here, and is not any more. The window answered from its recents cache —
        // `ServerConfiguration.default.port`, zero counts and a fabricated `modifiedAt` for every
        // project it did not have open — and the row called it a contract difference on the grounds
        // that "the recents list is the app's own listing and is on screen". That justified the
        // *source*, not the wrong values, and a script cannot use a listing whose ports are invented.
        // Both hosts read the store now; see `projectListReportsTheStoredProjects`.
        ContractDifference(
            kind: .serverStart,
            window: #"ok, "Starting the server on port N. Poll `mimic server status` to confirm.""#,
            headless: #"ok, "Server running at http://127.0.0.1:N." once it is actually bound"#,
            reason: """
            `MockServerRuntime` starts the engine from a task, so the window can only report the \
            intent; the service awaits `engine.start` and can report the bound address — which is \
            also why this suite never drives the service's, since doing so would open a socket. The \
            difference is now confined to that: a start against an instance already running on the \
            port asked for gets "Server already running on port N." from both, and a start that \
            collides with a lifecycle change already in flight gets `server.busy` from both. What \
            counts as "in flight" is not the same on the two — the service holds its flag across \
            `engine.start`, the window reads `MockServerRuntime.serverState`, which stays `.starting` \
            after the command that began it has returned — but the answer a caller sees is.
            """
        ),
        ContractDifference(
            kind: .serverStop,
            window: #"ok, "Stopping the server." — the runtime shuts the engine down from a task"#,
            headless: #"ok, "Server stopped." once the engine has actually stopped"#,
            reason: """
            The same asynchronous lifecycle as serverStart, from the other end, and now the whole of \
            the difference: both answer a stop with nothing running "Server is not running.", and \
            both refuse one that collides with a lifecycle change in flight with `server.busy`. The \
            window used to answer "Stopping the server." from *every* state — including `.starting`, \
            which is the state `MockServerRuntime.stopServer()` drops the command in — so the \
            sentence was the one thing about it that could not be trusted. See \
            `serverLifecycleReportsWhatTheRuntimeDid`.
            """
        ),
    ]

    /// The table above can only ever name host-scoped commands.
    ///
    /// A project-scoped command has exactly one implementation — `ProjectCommandExecutor` — so it
    /// cannot legitimately differ between hosts, and listing one here would be a licence to drift
    /// rather than a description of one.
    @Test("Only host-scoped commands are allowed to differ")
    func contractDifferencesNameOnlyHostScopedCommands() {
        for difference in Self.contractDifferences {
            #expect(
                difference.kind.scope == .host,
                "\(difference.kind.rawValue) is project-scoped: one implementation, so it cannot differ"
            )
            // A row describing the same answer twice is a copy-paste, not a difference.
            #expect(
                difference.window != difference.headless,
                "\(difference.kind.rawValue) is listed as a difference but describes one answer twice"
            )
        }
        let kinds = Self.contractDifferences.map(\.kind)
        #expect(Set(kinds).count == kinds.count, "A command is listed twice in contractDifferences.")
    }

    /// The optimistic half of the contract, pinned: the window reports the intent and opens the
    /// project anyway, so the follow-up `state` a caller is told to poll really does confirm it.
    @Test("Project creation is answered optimistically by the window and completely by the service")
    func projectCreateIsOptimisticOnTheWindowHost() async throws {
        let hosts = try makeHosts()
        let responses = await run(.projectCreate(name: "Checkout", port: 9099), on: hosts)

        #expect(responses.window.ok)
        #expect(responses.window.result?.message == "Creating and opening project \"Checkout\".")
        #expect(responses.window.result?.project == nil)

        #expect(responses.headless.ok)
        #expect(responses.headless.result?.message == "Created and opened project \"Checkout\".")
        #expect(responses.headless.result?.project?.name == "Checkout")

        // The half that makes the optimism honest rather than a lie.
        let state = try await expectParity(.state, on: hosts)
        #expect(state.window.result?.state?.project?.name == "Checkout")
        #expect(state.headless.result?.state?.project?.name == "Checkout")
    }

    /// Import differs only in tense — and hands back the same document from both, which is the part a
    /// caller reads.
    @Test("Import differs in tense only")
    func projectImportDiffersInTenseOnly() async throws {
        let hosts = try makeHosts()
        let document = MockProject(name: "Fixture")

        let responses = try await expectParity(
            .projectImport(project: document, activate: false),
            on: hosts
        )

        #expect(responses.window.result?.message?.hasPrefix("Importing project \"Fixture\"") == true)
        #expect(responses.headless.result?.message?.hasPrefix("Imported project \"Fixture\"") == true)
        #expect(responses.window.result?.project?.id == document.id)
        #expect(responses.headless.result?.project?.id == document.id)
    }

    /// Server lifecycle on the window's host, asserted by what the engine was asked to do.
    ///
    /// This test used to assert the *sentences* — `#expect(stopped.window.result?.message ==
    /// "Stopping the server.")` — and that is exactly how the defect it now covers survived a green
    /// suite for as long as it did. `AppControlHost` answered that sentence from every state, while
    /// `MockServerRuntime.stopServer()` acts only on `.running` and drops the command everywhere
    /// else. `.starting` is where *every* stop issued straight after a start arrives, because
    /// `startServer()` publishes `.starting` and returns with the bind still ahead of it — so
    /// `mimic server start && mimic server stop` reported a stop it had not made and left the server
    /// up. An assertion on the reply agreed with the bug; only the engine can tell them apart.
    ///
    /// Only the window is driven here: the service's start would put a real listener on the port, and
    /// a parity suite has no business opening sockets. What the service answers is recorded in
    /// ``contractDifferences`` and covered by `ControlPlaneTests`.
    @Test("Server lifecycle is answered by what the runtime did, not by a fixed sentence")
    func serverLifecycleReportsWhatTheRuntimeDid() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts, port: 9099)

        // Nothing is running, so there is nothing to stop — and both hosts now say so in the same
        // words, which is why this one goes through `expectParity`.
        let idle = try await expectParity(.serverStop, on: hosts)
        #expect(idle.window.ok)
        #expect(idle.window.result?.message == "Server is not running.")
        #expect(idle.window.result?.server?.state == "stopped")
        let stopsBeforeAnyStart = await hosts.engine.stopCount
        #expect(stopsBeforeAnyStart == 0)

        // Held open, so the runtime is `.starting` for as long as this test needs it to be rather
        // than for however long the scheduler happens to take.
        await hosts.engine.holdStart()
        let started = await hosts.window.execute(.serverStart(port: nil))
        #expect(started.ok)
        #expect(
            started.result?.message
                == "Starting the server on port 9099. Poll `mimic server status` to confirm."
        )
        // Reported as intent, not as a bind: `.starting` is what the runtime is in when the arm
        // returns, and saying "running" here would be the same class of claim as the stop below.
        #expect(started.result?.server?.state == "starting")

        // The defect, driven. A stop arriving before the engine has bound must not be answered with
        // a success sentence, and must not reach the engine.
        let duringStart = await hosts.window.execute(.serverStop)
        #expect(duringStart.ok == false)
        #expect(duringStart.error?.code == "server.busy")
        let stopsDuringStart = await hosts.engine.stopCount
        #expect(stopsDuringStart == 0)

        // The same window from the other end: a second start would have been dropped by
        // `startServer()`'s own guard while the reply claimed a bind on port 9099.
        let restart = await hosts.window.execute(.serverStart(port: nil))
        #expect(restart.ok == false)
        #expect(restart.error?.code == "server.busy")
        // Polled, not read once. `MockServerRuntime.startServer()` publishes `.starting`
        // synchronously and reaches `engine.start` in a task of its own — which is the whole window
        // this test exists to describe — so a bare read here races the bind it is asserting. It
        // would pass on a fast runner and fail on a loaded one, and a flaky assertion inside a test
        // named for a concurrency defect is worse than none.
        let startEngine = hosts.engine
        try await waitUntilAsync { await startEngine.startedPorts == [9099] }

        // Bound only after the fixture lets go. `appState` and `engine` are pulled out into locals
        // because the two polls run in differently-isolated closures — one on the main actor reading
        // the session, one nonisolated asking the engine — and `ParityHosts` is neither.
        let appState = hosts.appState
        let engine = hosts.engine
        await engine.releaseStart()
        try await waitUntil { appState.serverState.runningPort == 9099 }

        // Up, so a start is answered as such — in the service's words — instead of reporting a bind
        // that `startServer()` would have dropped.
        let again = await hosts.window.execute(.serverStart(port: nil))
        #expect(again.ok)
        #expect(again.result?.message == "Server already running on port 9099.")
        let portsAfterSecondStart = await engine.startedPorts
        #expect(portsAfterSecondStart == [9099])

        // …and only now is "Stopping the server." true. The engine is the proof; the runtime reaches
        // it from a task of its own, so the count is polled rather than read.
        let stopping = await hosts.window.execute(.serverStop)
        #expect(stopping.ok)
        #expect(stopping.result?.message == "Stopping the server.")
        try await waitUntilAsync { await engine.stopCount == 1 }
    }

    // MARK: - Divergences

    /// Was a DIVERGENCE, now parity: `project list` reports the store from both hosts.
    ///
    /// The window's arm mapped `AppState.recentProjects`, and recents cannot answer the question: it
    /// is a ten-entry `UserDefaults` cache holding an id, a name and a last-opened date, so every
    /// other field of a `ProjectSummary` was invented. Every project the session did not have open was
    /// reported as serving on `ServerConfiguration.default.port` with no endpoints and no journeys,
    /// and every row — the open one included — carried `modifiedAt: Date()`, the instant of the call.
    /// A script that listed projects to find the port to point a client at was handed 8080 for all of
    /// them, while the identical command against a daemon answered correctly.
    ///
    /// It went unnoticed because this suite compared which fields were populated: `projects` was
    /// populated on both sides, so the row was recorded in ``contractDifferences`` as a legitimate
    /// difference of *source* rather than read as a wrong answer. Value comparison is what turns that
    /// into a failure, and this test is what makes it specific.
    ///
    /// The endpoint and the journey are added *after* the project is created on purpose: on the
    /// window those edits go through the autosave debounce, so the stored row still says zero when
    /// this runs. That is the case the open-project overlay exists for — and the case a listing built
    /// from the store alone would get wrong in the opposite direction.
    @Test("Both hosts list the stored projects, with the port and counts each one really has")
    func projectListReportsTheStoredProjects() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts, name: "Checkout", port: 9099)
        try await expectParity(
            .endpointCreate(name: "Login", method: .post, path: "/login", spec: nil),
            on: hosts
        )
        try await expectParity(.journeyAddTemplate(templateID: "payment-retry", name: "Flow"), on: hosts)

        let listed = try await expectParity(.projectList, on: hosts)

        let windowProjects = try #require(listed.window.result?.projects)
        #expect(windowProjects.count == 1)
        // The three the window used to fabricate. Each is asserted against the value the project
        // actually holds, so a listing that fell back to the defaults again fails here rather than
        // only in `expectParity`'s value comparison.
        #expect(windowProjects.first?.name == "Checkout")
        #expect(windowProjects.first?.port == 9099)
        #expect(windowProjects.first?.endpointCount == 1)
        #expect(windowProjects.first?.journeyCount == 1)

        let headlessProjects = try #require(listed.headless.result?.projects)
        #expect(headlessProjects.map(\.port) == windowProjects.map(\.port))
        #expect(headlessProjects.map(\.endpointCount) == windowProjects.map(\.endpointCount))
        #expect(headlessProjects.map(\.journeyCount) == windowProjects.map(\.journeyCount))
    }

    /// Was a DIVERGENCE, now parity: `projectExport` takes a project reference and both hosts honour
    /// it.
    ///
    /// The window's arm used to bind no associated value at all — `case .projectExport:` — so the
    /// reference was dropped on the floor: `mimic project export Other` returned whatever happened to
    /// be open, and `mimic project export Nonexistent` returned a document instead of an error. It
    /// now resolves the reference against the store, mirroring `MimicControlService`.
    ///
    /// The one thing that is deliberately *not* symmetric is where the open project comes from: the
    /// window answers it out of the session rather than re-reading the store, because an export taken
    /// straight after an edit has to contain that edit, and the edit is sitting in the autosave
    /// debounce. Anything else exists only in the store, for both hosts.
    @Test("Both hosts resolve the project reference on export")
    func projectExportHonoursItsReference() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts, name: "Checkout")

        let missing = try await expectParity(.projectExport(project: .name("Nonexistent")), on: hosts)
        #expect(missing.window.ok == false)
        #expect(missing.window.error?.code == "project.notFound")
        #expect(missing.headless.error?.code == "project.notFound")

        // Naming the open project is the case that has to keep working, and it is the one the window
        // answers from the session.
        let named = try await expectParity(.projectExport(project: .name("Checkout")), on: hosts)
        #expect(named.window.result?.project?.name == "Checkout")
        #expect(named.headless.result?.project?.name == "Checkout")

        // …and so does asking for whatever is open.
        let open = try await expectParity(.projectExport(project: nil), on: hosts)
        #expect(open.window.result?.project?.name == "Checkout")
        #expect(open.headless.result?.project?.name == "Checkout")
    }

    /// Was a DIVERGENCE, now parity: a project id that names nothing is refused by both hosts.
    ///
    /// The window used to take `ref.id` on trust and search only when it had a name instead, so no
    /// step of `projectOpen`, `projectDelete` or `projectDuplicate` ever checked that the id existed:
    /// `mimic project delete --id <any uuid>` answered "Deleted the project." having deleted nothing,
    /// while the identical command against a daemon reported `project.notFound`. All three now
    /// resolve through the store, which is the only thing that can answer the question.
    ///
    /// All three are driven, rather than letting `projectDelete` stand in for them: they took the same
    /// shape by having been written the same way, which is exactly the property that stops holding
    /// when somebody edits one of them.
    @Test(
        "An unknown project id is refused by both hosts",
        arguments: [
            ControlCommand.projectDelete(project: .id(UUID())),
            .projectOpen(project: .id(UUID())),
            .projectDuplicate(project: .id(UUID())),
        ]
    )
    func anUnknownProjectIDIsRefusedByBothHosts(command: ControlCommand) async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)

        let responses = try await expectParity(command, on: hosts)
        #expect(responses.window.ok == false)
        #expect(responses.window.error?.code == "project.notFound")
        #expect(responses.headless.error?.code == "project.notFound")
    }

    /// The other half of that resolution, and the reason it is not simply "ask the store": the open
    /// project counts whether or not the store has caught up with it.
    ///
    /// `projectCreate` answers before its write lands on the window's host — that is a declared
    /// contract difference — so a script that creates a project and immediately names it would be told
    /// it does not exist if resolution went only to the store.
    @Test("A reference naming the open project resolves even before its write has landed")
    func theOpenProjectResolvesWithoutWaitingForTheStore() async throws {
        let hosts = try makeHosts()
        let created = await run(.projectCreate(name: "Just created", port: 9098), on: hosts)
        #expect(created.window.ok)

        let responses = try await expectParity(.projectExport(project: .name("Just created")), on: hosts)
        #expect(responses.window.result?.project?.name == "Just created")
    }

    /// A name that matches nothing is refused by both, and always was — the window had to search for
    /// a name, so only the reference that skipped the lookup was ever accepted. Kept because it is the
    /// control case for the parity above: if this ever starts disagreeing, the resolution changed
    /// rather than the reference handling.
    @Test("An unknown project name is refused by both hosts")
    func anUnknownProjectNameIsRefusedByBothHosts() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)

        let byName = try await expectParity(.projectDelete(project: .name("Nonexistent")), on: hosts)
        #expect(byName.window.error?.code == "project.notFound")
        #expect(byName.headless.error?.code == "project.notFound")
    }

    /// The one divergence still standing, and the only test in this suite that is *supposed* to fail.
    ///
    /// `projectClose` names the project it closed from the service and not from the window, and the
    /// two answer a close with nothing open differently. Unlike the rest of the project lifecycle this
    /// is not an artefact of asynchrony — `AppState.closeProject()` is synchronous and the name is
    /// right there in `currentProject`. The two sentences simply drifted.
    ///
    /// It is wrapped in `withKnownIssue` rather than asserted the way it stands, because a test that
    /// pins current behaviour reports as a **pass** — and a green suite claiming "host parity" with a
    /// known divergence inside it is exactly the report this file exists to stop anyone trusting. As
    /// a known issue the run says so, and the day somebody fixes the wording this fails as an
    /// *unexpected pass*, which is the notification that the exception can be deleted.
    ///
    /// Message parity is not a general contract here — `expectParity` never compares prose, and `ping`
    /// and `logClear` are deliberately unpinned for that reason. This one is different because the
    /// two hosts differ in whether the reply names the project at all, which is a difference in what a
    /// caller can read out of it rather than in how it is worded.
    @Test("KNOWN ISSUE: closing a project is reported differently by each host")
    func projectCloseIsReportedDifferently() async throws {
        let empty = try makeHosts()
        let withNothingOpen = await run(.projectClose, on: empty)
        #expect(withNothingOpen.window.ok)
        #expect(withNothingOpen.headless.ok)

        let seeded = try makeHosts()
        try await seedProject(seeded, name: "Checkout")
        let withAProjectOpen = await run(.projectClose, on: seeded)

        withKnownIssue(
            """
            `projectClose` answers "Closed the project." from the window and "No project was open." / \
            "Closed project \\"X\\"." from the service. Neither host was corrected when the other \
            changed, and nothing needs to be asynchronous for them to agree.
            """
        ) {
            #expect(withNothingOpen.window.result?.message == withNothingOpen.headless.result?.message)
            #expect(withAProjectOpen.window.result?.message == withAProjectOpen.headless.result?.message)
        }

        // What each host says today, so the divergence is described and not merely flagged.
        #expect(withNothingOpen.window.result?.message == "Closed the project.")
        #expect(withNothingOpen.headless.result?.message == "No project was open.")
        #expect(withAProjectOpen.window.result?.message == "Closed the project.")
        #expect(withAProjectOpen.headless.result?.message == "Closed project \"Checkout\".")
    }

    /// Was a DIVERGENCE, now parity: `journeyAdvance` carries a `journeyStatus` from both hosts.
    ///
    /// The window used to dispatch the advance and then report `MockServerRuntime`'s *mirror* of the
    /// cursor, which the advance it had just requested had not reached — so the reply carried the
    /// position from before the command at best, and no position at all on a script's first advance,
    /// which is when nothing has populated the mirror. It now awaits the engine and reports the
    /// engine's own answer, falling back to the not-yet-started journey exactly as `journeyRestart`
    /// and `journeyStatus` beside it already did.
    ///
    /// **What this suite can and cannot see.** Field presence is the whole of the parity claim here —
    /// `journeyAdvance` is the one command whose `journeyStatus` is allowed to differ, and its
    /// `message` with it. The window's engine in this fixture is `ParityStubEngine`, which takes the
    /// protocol's default `advanceJourney()` and reports no cursor at all, so the window's reply comes
    /// from the fallback while the service's comes from a real engine that moved; the reasons sit in
    /// ``allowancesByCommand``. Giving the stub a real cursor would not fix it — the runtime pushes
    /// the journey to the engine from an unstructured task, so whether the engine has it by the time
    /// the advance arrives is a race, and the assertion would be flaky rather than strict. That the
    /// *engine's* answer is what gets reported is asserted where an engine can be made to answer:
    /// `AppStateAndViewTests.controlHostAdvanceReportsTheEngineAnswer`.
    @Test("Advancing a journey reports a status from both hosts")
    func journeyAdvanceReportsAStatusFromBothHosts() async throws {
        let hosts = try makeHosts()
        try await seedProject(hosts)
        try await expectParity(.journeyAddTemplate(templateID: "payment-retry", name: "Flow"), on: hosts)
        try await expectParity(.journeyActivate(journey: .name("Flow")), on: hosts)

        let responses = try await expectParity(.journeyAdvance, on: hosts)

        #expect(responses.window.ok)
        #expect(responses.headless.ok)
        #expect(responses.window.result?.journeyStatus?.journeyName == "Flow")
        #expect(responses.headless.result?.journeyStatus?.journeyName == "Flow")

        // The query beside it answers too, which is what makes this a property of the command surface
        // rather than of one arm.
        //
        // Deliberately `run` and not `expectParity`: the advance above moved the service's cursor and
        // could not move the window's, because `ParityStubEngine` has none. By this point in *this*
        // test the two statuses have genuinely diverged, and comparing them would be comparing a stub
        // against a real engine. Everywhere else in this suite `journeyStatus` goes through
        // `expectParity` and is compared in full — see `aScriptedFlowAgreesAtEveryStep`, where both
        // hosts are asked for it with the cursor untouched.
        let queried = await run(.journeyStatus, on: hosts)
        #expect(queried.window.ok)
        #expect(queried.headless.ok)
        #expect(queried.window.result?.journeyStatus?.journeyName == "Flow")
        #expect(queried.headless.result?.journeyStatus?.journeyName == "Flow")
    }
}
