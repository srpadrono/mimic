import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in FoundationNetworking on Linux, not Foundation. Without this the CLI and the
// tests that speak HTTP do not compile there — and CI runs on Linux.
import FoundationNetworking
#endif
import Testing
@testable import Domain
@testable import MimicCLICore

/// What each `mimic` verb actually asks the instance to do.
///
/// Until `ControlTransport` existed there was no way to find out. A subcommand builds its command and
/// posts it in one expression — `options.client().send(.ping)` — and `GlobalOptions.client()` handed
/// back a concrete `ControlClient` that built its own `URLSession` in its initialiser, so nothing
/// could stand between the two. The suite next door tests *parsing*: that `mimic endpoint update GET
/// /a --delay 100` is accepted. Which `ControlCommand` that produces, and how many, was covered by
/// nothing at all — and the compositions are where the interesting behaviour is, because a single CLI
/// verb can be three commands with a branch between them.
///
/// `ControlTransportOverride` is a task local, so binding one here substitutes the transport for the
/// whole subcommand tree without any production call site knowing: `MimicCommand.run` is driven
/// exactly as the process driver drives it, argv in, exit code out.
/// The one-command verbs and the command each must emit.
///
/// A file-scope constant with an explicit element type rather than a literal inside `@Test(arguments:)`:
/// forty-odd heterogeneous tuples of implicit member expressions is exactly the shape that turns into
/// "the compiler is unable to type-check this expression in reasonable time", and the annotation lets
/// each element be checked on its own.
private let singleCommandVerbs: [([String], ControlCommand)] = [
    (["ping"], .ping),
    (["state"], .state),
    (["commands"], .describeCommands),
    (["reset", "--scope", "logs"], .reset(scope: .logs)),
    (["reset"], .reset(scope: .all)),
    (["server", "start", "--port", "8080"], .serverStart(port: 8080)),
    (["server", "start"], .serverStart(port: nil)),
    (["server", "stop"], .serverStop),
    (["server", "status"], .serverStatus),
    (["server", "configure", "--port", "9000", "--delay", "250"],
     .serverConfigure(port: 9000, globalDelayMs: 250)),
    (["project", "list"], .projectList),
    (["project", "create", "Checkout", "--port", "9000"], .projectCreate(name: "Checkout", port: 9000)),
    (["project", "open", "Checkout"], .projectOpen(project: .name("Checkout"))),
    (["project", "close"], .projectClose),
    (["project", "delete", "Checkout"], .projectDelete(project: .name("Checkout"))),
    (["project", "rename", "New name"], .projectRename(name: "New name")),
    (["project", "duplicate", "Checkout"], .projectDuplicate(project: .name("Checkout"))),
    (["project", "export"], .projectExport(project: nil)),
    (["project", "export", "Other"], .projectExport(project: .name("Other"))),
    (["endpoint", "list"], .endpointList),
    (["endpoint", "get", "GET", "/a"], .endpointGet(endpoint: .route(.get, "/a"))),
    (["endpoint", "delete", "GET", "/a"], .endpointDelete(endpoint: .route(.get, "/a"))),
    (["endpoint", "duplicate", "GET", "/a"], .endpointDuplicate(endpoint: .route(.get, "/a"))),
    (["scenario", "list", "GET", "/a"], .scenarioList(endpoint: .route(.get, "/a"))),
    (["scenario", "update", "GET", "/a", "Error", "--status", "500"],
     .scenarioUpdate(
        endpoint: .route(.get, "/a"),
        scenario: .name("Error"),
        spec: ScenarioSpec(statusCode: 500)
     )),
    (["scenario", "delete", "GET", "/a", "Error"],
     .scenarioDelete(endpoint: .route(.get, "/a"), scenario: .name("Error"))),
    (["scenario", "activate", "GET", "/a", "Error"],
     .scenarioActivate(endpoint: .route(.get, "/a"), scenario: .name("Error"))),
    (["journey", "list"], .journeyList),
    (["journey", "get", "Flow"], .journeyGet(journey: .name("Flow"))),
    (["journey", "templates"], .journeyTemplateList),
    (["journey", "delete", "Flow"], .journeyDelete(journey: .name("Flow"))),
    (["journey", "duplicate", "Flow"], .journeyDuplicate(journey: .name("Flow"))),
    (["journey", "update", "Flow", "--completion", "restart"],
     .journeyUpdate(journey: .name("Flow"), spec: JourneySpec(completion: .restart))),
    (["journey", "activate", "Flow"], .journeyActivate(journey: .name("Flow"))),
    // `deactivate` is `journeyActivate` with no name — one of the three CLI verbs that are
    // compositions of catalog entries rather than entries of their own.
    (["journey", "deactivate"], .journeyActivate(journey: nil)),
    (["journey", "restart"], .journeyRestart),
    (["journey", "advance"], .journeyAdvance),
    (["journey", "status"], .journeyStatus),
    (["journey", "step", "add", "Flow", "GET", "/a", "--status", "500"],
     .journeyStepAdd(
        journey: .name("Flow"),
        step: JourneyStepSpec(method: .get, path: "/a", statusCode: 500),
        atIndex: nil
     )),
    (["journey", "step", "update", "Flow", "--index", "0", "--status", "503"],
     .journeyStepUpdate(journey: .name("Flow"), step: .index(0), spec: JourneyStepSpec(statusCode: 503))),
    (["journey", "step", "remove", "Flow", "--index", "1"],
     .journeyStepRemove(journey: .name("Flow"), step: .index(1))),
    (["journey", "step", "move", "Flow", "--index", "0", "--to", "2"],
     .journeyStepMove(journey: .name("Flow"), step: .index(0), toIndex: 2)),
    (["log", "list", "--limit", "20"], .logList(limit: 20, unmatchedOnly: nil)),
    (["log", "list", "--unmatched"], .logList(limit: nil, unmatchedOnly: true)),
    (["log", "clear"], .logClear),
]

@Suite("CLI emitted commands")
struct EmittedCommandTests {

    // MARK: - The recorder

    /// Records every command a run emits and answers each one plausibly enough for the run to
    /// continue.
    ///
    /// The answers matter as much as the recording: `mimic endpoint create` reads `result.endpoint`
    /// out of its first reply and only issues the second command if it is there, so a transport that
    /// answered a bare message would silently test the short branch of every composition.
    final class RecordingTransport: ControlTransport, @unchecked Sendable {
        let baseURL = URL(string: "http://127.0.0.1:8787")!

        private let lock = NSLock()
        private var recorded: [ControlCommand] = []
        private let answer: @Sendable (ControlCommand) -> ControlResponse

        init(answer: @escaping @Sendable (ControlCommand) -> ControlResponse = RecordingTransport.plausibleAnswer) {
            self.answer = answer
        }

        var commands: [ControlCommand] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var kinds: [CommandKind] { commands.map(\.kind) }

        func send(_ command: ControlCommand) async throws -> ControlResponse {
            lock.lock()
            recorded.append(command)
            lock.unlock()
            return answer(command)
        }

        func isReachable() async -> Bool { true }

        // Fixtures are `static let`, not computed: `endpoint create` sends the id it was handed back,
        // so a fresh `Endpoint` per call would make the ids in the recording unassertable.
        static let scenario = Scenario(name: "Default", statusCode: 200, body: "{}")
        static let endpoint = Endpoint(
            name: "Sample",
            method: .get,
            path: "/a",
            scenarios: [scenario],
            activeScenarioID: scenario.id
        )
        static let journey = Journey(
            name: "Flow",
            steps: [
                JourneyStep(
                    name: "one",
                    method: .get,
                    path: "/a",
                    outcome: .respond(JourneyResponse(statusCode: 200))
                ),
            ]
        )
        static let project = MockProject(name: "Checkout")

        @Sendable
        static func plausibleAnswer(_ command: ControlCommand) -> ControlResponse {
            switch command.kind {
            case .endpointCreate, .endpointGet, .endpointUpdate, .endpointDuplicate:
                .success(.init(endpoint: endpoint))
            case .scenarioCreate:
                .success(.init(scenario: scenario))
            case .journeyGet, .journeyCreate, .journeyAddTemplate, .journeyUpdate, .journeyDuplicate:
                .success(.init(journey: journey))
            case .projectExport:
                .success(.init(project: project))
            default:
                .success(.message("ok"))
            }
        }
    }

    /// Runs one invocation through the real subcommand tree and hands back what it emitted.
    @discardableResult
    static func emitted(
        _ arguments: [String],
        transport: RecordingTransport = RecordingTransport(),
        exitCode: Int32? = 0,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [ControlCommand] {
        let status = await ControlTransportOverride.$current.withValue(transport) {
            await MimicCommand.run(arguments: arguments)
        }
        if let exitCode {
            #expect(
                status == exitCode,
                "mimic \(arguments.joined(separator: " ")) exited \(status)",
                sourceLocation: sourceLocation
            )
        }
        return transport.commands
    }

    // MARK: - Files the file-taking verbs need

    static func temporaryFile(_ contents: String, extension ext: String = "json") throws -> String {
        let path = NSTemporaryDirectory() + "mimic-emitted-\(UUID().uuidString).\(ext)"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    static let journeyFileJSON = """
    {
      "name": "Flow",
      "steps": [
        { "name": "Login", "method": "POST", "path": "/login", "statusCode": 200 },
        { "name": "Fails", "method": "GET",  "path": "/account-summary", "statusCode": 500 }
      ]
    }
    """

    // MARK: - One verb, one command

    /// The verbs that are a single `ControlCommand`, asserted by equality rather than by kind: the
    /// payload is the part a script depends on, and it is the part a refactor silently changes.
    @Test("Single-command verbs emit exactly the command they name", arguments: singleCommandVerbs)
    func singleCommandVerb(invocation: [String], expected: ControlCommand) async {
        let recorded = await Self.emitted(invocation)
        #expect(
            recorded == [expected],
            "mimic \(invocation.joined(separator: " ")) emitted \(recorded)"
        )
    }

    // MARK: - Compositions

    /// `endpoint create` is three commands with a branch in the middle: create, then — only when the
    /// invocation carried response options — a `scenarioUpdate` against the scenario the create made
    /// active, then a `get` so the caller sees the finished endpoint.
    ///
    /// The branch is the point. Response options describe the endpoint's *default scenario*, and
    /// applying them as a second command is what keeps `endpointCreate` a single-purpose operation
    /// while one CLI invocation still produces a fully configured, serving endpoint.
    @Test("`endpoint create` issues create → scenarioUpdate → get only when a response is given")
    func endpointCreateComposition() async {
        let plain = await Self.emitted(["endpoint", "create", "POST", "/login"])
        #expect(plain.map(\.kind) == [.endpointCreate])

        let configured = await Self.emitted(
            ["endpoint", "create", "POST", "/login", "--status", "201", "--body", "{}"]
        )
        #expect(configured.map(\.kind) == [.endpointCreate, .scenarioUpdate, .endpointGet])

        // The second command edits the scenario the first one made active, addressed by id — not by
        // the route the caller typed, which would re-resolve and could pick a different endpoint.
        #expect(
            configured[1]
                == .scenarioUpdate(
                    endpoint: .id(RecordingTransport.endpoint.id),
                    scenario: .id(RecordingTransport.scenario.id),
                    spec: ScenarioSpec(statusCode: 201, body: "{}")
                )
        )
        #expect(configured[2] == .endpointGet(endpoint: .id(RecordingTransport.endpoint.id)))
    }

    /// `endpoint update` branches twice: on whether anything about the *endpoint* changed, and on
    /// whether anything about its *response* did. The response half also has to look the endpoint up
    /// first, because "the endpoint's response" means whichever scenario is active.
    @Test("`endpoint update` emits only the halves the invocation asked for")
    func endpointUpdateComposition() async {
        let endpointOnly = await Self.emitted(["endpoint", "update", "GET", "/a", "--delay", "100"])
        #expect(endpointOnly.map(\.kind) == [.endpointUpdate, .endpointGet])

        let responseOnly = await Self.emitted(["endpoint", "update", "GET", "/a", "--status", "500"])
        #expect(responseOnly.map(\.kind) == [.endpointGet, .scenarioUpdate, .endpointGet])

        let both = await Self.emitted(
            ["endpoint", "update", "GET", "/a", "--delay", "100", "--status", "500"]
        )
        #expect(both.map(\.kind) == [.endpointUpdate, .endpointGet, .scenarioUpdate, .endpointGet])

        // Nothing to change is bad usage, and nothing is sent at all.
        let empty = await Self.emitted(["endpoint", "update", "GET", "/a"], exitCode: 2)
        #expect(empty.isEmpty)
    }

    /// The branch a script actually trips over: an endpoint with no active scenario has no response
    /// to edit, so the run stops after the lookup rather than guessing which scenario was meant.
    @Test("`endpoint update --status` stops after the lookup when there is no active scenario")
    func endpointUpdateWithoutAnActiveScenario() async {
        let scenarioless = Endpoint(name: "Sample", method: .get, path: "/a", scenarios: [])
        let transport = RecordingTransport { command in
            switch command.kind {
            case .endpointGet: .success(.init(endpoint: scenarioless))
            default: .success(.message("ok"))
            }
        }

        let recorded = await Self.emitted(
            ["endpoint", "update", "GET", "/a", "--status", "500"],
            transport: transport,
            exitCode: 2
        )
        #expect(recorded.map(\.kind) == [.endpointGet])
    }

    /// `scenario create --activate` is create-then-activate, addressed by the id the create handed
    /// back — so two scenarios sharing a name cannot make the wrong one live.
    @Test("`scenario create` follows with an activate only when asked")
    func scenarioCreateComposition() async {
        let plain = await Self.emitted(["scenario", "create", "GET", "/a", "Error", "--status", "500"])
        #expect(plain.map(\.kind) == [.scenarioCreate])

        let activated = await Self.emitted(
            ["scenario", "create", "GET", "/a", "Error", "--status", "500", "--activate"]
        )
        #expect(activated.map(\.kind) == [.scenarioCreate, .scenarioActivate])
        #expect(
            activated[1]
                == .scenarioActivate(
                    endpoint: .route(.get, "/a"),
                    scenario: .id(RecordingTransport.scenario.id)
                )
        )
    }

    @Test("`journey create --activate` and `journey add-template --activate` both follow with an activate")
    func journeyCreationCompositions() async throws {
        let file = try Self.temporaryFile(Self.journeyFileJSON)
        defer { try? FileManager.default.removeItem(atPath: file) }

        let created = await Self.emitted(["journey", "create", "Flow", "--file", file, "--activate"])
        #expect(created.map(\.kind) == [.journeyCreate, .journeyActivate])
        // Created by the name the argument gave, and activated by that same name — a file's own name
        // must not silently win.
        #expect(created[1] == .journeyActivate(journey: .name("Flow")))

        let templated = await Self.emitted(
            ["journey", "add-template", "session-expiry", "--activate"]
        )
        #expect(templated.map(\.kind) == [.journeyAddTemplate, .journeyActivate])
        // By id here, because the template decides the name unless `--name` overrode it.
        #expect(templated[1] == .journeyActivate(journey: .id(RecordingTransport.journey.id)))
    }

    /// `journey import` is a lookup and then one of two writes, which is the only place in the CLI
    /// where the *same* invocation emits a different second command depending on what it found.
    @Test("`journey import` creates when the name is free and updates when --replace is given")
    func journeyImportComposition() async throws {
        let file = try Self.temporaryFile(Self.journeyFileJSON)
        defer { try? FileManager.default.removeItem(atPath: file) }

        // Nothing by that name: the lookup fails and the import creates.
        let absent = RecordingTransport { command in
            switch command.kind {
            case .journeyGet: .failure(.journeyNotFound(.name("Flow")))
            default: .success(.message("ok"))
            }
        }
        let created = await Self.emitted(["journey", "import", file], transport: absent)
        #expect(created.map(\.kind) == [.journeyGet, .journeyCreate])

        // Something by that name, and no `--replace`: bad usage, and nothing is written.
        let refused = await Self.emitted(["journey", "import", file], exitCode: 2)
        #expect(refused.map(\.kind) == [.journeyGet])

        // Something by that name with `--replace`: the import updates in place.
        let replaced = await Self.emitted(["journey", "import", file, "--replace"])
        #expect(replaced.map(\.kind) == [.journeyGet, .journeyUpdate])
    }

    /// The three compositions that have no catalog entry because they *are* compositions of entries
    /// that do: export is a `journeyGet` rendered as a spec, and `step add-batch` is one mutation
    /// rather than N — which is the whole reason it exists, since N separate adds mean N autosaves.
    @Test("`journey export` is a get, and `step add-batch` is one journeyStepsAdd")
    func journeyFileCompositions() async throws {
        let file = try Self.temporaryFile(Self.journeyFileJSON)
        defer { try? FileManager.default.removeItem(atPath: file) }

        let exported = await Self.emitted(["journey", "export", "Flow"])
        #expect(exported == [.journeyGet(journey: .name("Flow"))])

        let batched = await Self.emitted(["journey", "step", "add-batch", "Flow", file, "--at", "0"])
        #expect(batched.count == 1)
        guard case let .journeyStepsAdd(journey, steps, atIndex) = batched[0] else {
            Issue.record("expected a journeyStepsAdd, got \(batched)")
            return
        }
        #expect(journey == .name("Flow"))
        #expect(atIndex == 0)
        #expect(steps.count == 2, "every step in the file goes in one change, not one command each")
        #expect(steps.map(\.path) == ["/login", "/account-summary"])
    }

    /// The document is compared field by field rather than by value equality with the one that was
    /// written: `ControlCoding` encodes dates as ISO-8601 without fractional seconds, so a `MockProject`
    /// that has been through a file is *deliberately* not `==` the one that went in. Asserting
    /// equality here would be asserting the date format.
    @Test("`project import` sends the decoded document, and --no-activate is the only thing that changes")
    func projectImportComposition() async throws {
        let document = MockProject(name: "Fixture")
        let file = try Self.temporaryFile(try ControlCoding.string(document, pretty: true))
        defer { try? FileManager.default.removeItem(atPath: file) }

        let activating = await Self.emitted(["project", "import", file])
        #expect(activating.count == 1)
        guard case let .projectImport(imported, activate) = activating[0] else {
            Issue.record("expected a projectImport, got \(activating)")
            return
        }
        #expect(imported.id == document.id, "the document's identity has to survive the file")
        #expect(imported.name == "Fixture")
        #expect(activate, "importing opens the document unless told otherwise")

        let quiet = await Self.emitted(["project", "import", file, "--no-activate"])
        guard case let .projectImport(_, quietActivate) = quiet[0] else {
            Issue.record("expected a projectImport, got \(quiet)")
            return
        }
        #expect(quietActivate == false)
    }

    // MARK: - The surface, from the CLI's side

    /// The meta-assertion: every command the catalog advertises is reachable from the CLI.
    ///
    /// `CommandCatalog` claims a `cli` spelling for all 47 kinds and the suite next door checks each
    /// one *parses*. This checks the other half — that running it actually emits that command — and it
    /// is `allCases`-driven, so a new `CommandKind` fails here until some invocation below produces
    /// it. That is the failure mode this cannot have: a command added to the surface, advertised by
    /// `mimic commands`, and reachable from no `mimic` invocation at all.
    ///
    /// The four `app`/`daemon` verbs are deliberately absent and must stay absent: they act on the OS
    /// process — launching the bundle, `SIGTERM`-ing a pid — so there is no running instance to ask,
    /// which is exactly why they have no catalog entry either.
    @Test("Every command kind is emitted by at least one CLI invocation")
    func everyCommandKindIsReachableFromTheCLI() async throws {
        let journeyFile = try Self.temporaryFile(Self.journeyFileJSON)
        let projectFile = try Self.temporaryFile(try ControlCoding.string(MockProject(name: "Fixture")))
        defer {
            try? FileManager.default.removeItem(atPath: journeyFile)
            try? FileManager.default.removeItem(atPath: projectFile)
        }

        let invocations: [[String]] = [
            ["ping"], ["state"], ["commands"], ["reset", "--scope", "logs"],
            ["server", "start", "--port", "8080"], ["server", "stop"], ["server", "status"],
            ["server", "configure", "--delay", "250"],
            ["project", "list"], ["project", "create", "Checkout", "--port", "9000"],
            ["project", "open", "Checkout"], ["project", "close"], ["project", "delete", "Checkout"],
            ["project", "rename", "New"], ["project", "duplicate", "Checkout"],
            ["project", "export"], ["project", "import", projectFile],
            ["endpoint", "list"], ["endpoint", "get", "GET", "/a"],
            ["endpoint", "create", "POST", "/login", "--status", "201"],
            ["endpoint", "update", "GET", "/a", "--delay", "100"],
            ["endpoint", "delete", "GET", "/a"], ["endpoint", "duplicate", "GET", "/a"],
            ["scenario", "list", "GET", "/a"],
            ["scenario", "create", "GET", "/a", "Error", "--status", "500", "--activate"],
            ["scenario", "update", "GET", "/a", "Error", "--body", "{}"],
            ["scenario", "delete", "GET", "/a", "Error"],
            ["scenario", "activate", "GET", "/a", "Error"],
            ["journey", "list"], ["journey", "get", "Flow"],
            ["journey", "create", "Flow", "--file", journeyFile],
            ["journey", "templates"], ["journey", "add-template", "session-expiry"],
            ["journey", "update", "Flow", "--completion", "restart"],
            ["journey", "delete", "Flow"], ["journey", "duplicate", "Flow"],
            ["journey", "activate", "Flow"], ["journey", "restart"], ["journey", "advance"],
            ["journey", "status"],
            ["journey", "step", "add", "Flow", "GET", "/a", "--status", "500"],
            ["journey", "step", "add-batch", "Flow", journeyFile],
            ["journey", "step", "update", "Flow", "--index", "0", "--status", "503"],
            ["journey", "step", "remove", "Flow", "--index", "1"],
            ["journey", "step", "move", "Flow", "--index", "0", "--to", "2"],
            ["log", "list", "--limit", "20"], ["log", "clear"],
        ]

        let transport = RecordingTransport()
        for invocation in invocations {
            _ = await Self.emitted(invocation, transport: transport)
        }

        let reached = Set(transport.kinds)
        let missing = Set(CommandKind.allCases).subtracting(reached)
        #expect(
            missing.isEmpty,
            "no CLI invocation emits: \(missing.map(\.rawValue).sorted().joined(separator: ", "))"
        )
    }

    /// Nothing in production binds the override, so a real invocation still builds the client it
    /// always built. Asserted because the seam is only safe while that stays true.
    @Test("With nothing bound, the transport is the real client")
    func theOverrideIsUnboundByDefault() throws {
        #expect(ControlTransportOverride.current == nil)

        // Parsed rather than constructed, so the options are in the state a real invocation leaves
        // them in. An explicit `--url` also keeps this deterministic on a machine that happens to
        // have Mimic running: resolution takes it before it consults any discovery file.
        let options = try GlobalOptions.parse(["--url", "http://127.0.0.1:9911"])
        let client = try options.client()
        #expect(client is ControlClient)
        #expect(client.baseURL.absoluteString == "http://127.0.0.1:9911")
    }
}

/// The five ways `ControlClient.send` can read a reply, and the two ways `isReachable` can.
///
/// None of them had ever been executed. What `Tests/MimicCLICoreTests` asserted about them was the
/// exit code each *failure value* carries — `CLIFailure.undecodable("x").exitCode == 4` — which is a
/// statement about the enum, not about the decoding that decides which case is thrown. The seam under
/// the transport is `ControlHTTPExchange`: it sits below every branch, so what runs here is the real
/// `send`, not a reimplementation of it.
@Suite("Control client transport")
struct ControlClientTransportTests {

    static func client(
        token: String? = nil,
        _ exchange: @escaping ControlHTTPExchange
    ) -> ControlClient {
        ControlClient(baseURL: URL(string: "http://127.0.0.1:8787")!, token: token, exchange: exchange)
    }

    static func http(_ status: Int, _ body: String) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }

    /// A box for what the exchange saw. `URLRequest` is not carried out of the closure — only the
    /// header dictionary, which is plain `[String: String]` and needs no reasoning about Sendability.
    final class CapturedHeaders: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: String] = [:]

        var value: [String: String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func record(_ headers: [String: String]?) {
            lock.lock()
            stored = headers ?? [:]
            lock.unlock()
        }
    }

    // MARK: - Reading a reply

    @Test("A well-formed envelope is returned as it stands, whatever the status")
    func envelopeIsReturned() async throws {
        let payload = try ControlCoding.string(ControlResponse.success(.message("Done")))
        let client = Self.client(Self.http(200, payload))

        let response = try await client.send(.ping)
        #expect(response.ok)
        #expect(response.result?.message == "Done")
    }

    /// A refusal *inside* an envelope is a successful send: Mimic answers a `409` with the same
    /// `ControlResponse` it answers a success with, and that error names the problem far better than
    /// the status number does. `Output.emit` is what turns `ok: false` into exit code 4.
    @Test("A refusal carried in an envelope is not a transport failure")
    func envelopedRefusalIsReturned() async throws {
        let payload = try ControlCoding.string(ControlResponse.failure(.noProjectOpen))
        let client = Self.client(Self.http(409, payload))

        let response = try await client.send(.endpointList)
        #expect(response.ok == false)
        #expect(response.error?.code == "project.noneOpen")
    }

    /// A `401` whose body is not an envelope — a proxy in front of the port, say. It used to be
    /// reported as "Unexpected response from Mimic: …", which reads as a decoding bug in this CLI and
    /// sends whoever hit it hunting through the wrong module.
    @Test("A 401 with no envelope reports the token, not a decoding problem")
    func unauthorizedIsNamed() async {
        let client = Self.client(Self.http(401, "<html>401 Unauthorized</html>"))

        await #expect(throws: CLIFailure.commandFailed(.unauthorized)) {
            _ = try await client.send(.ping)
        }
    }

    /// Any other non-2xx that does not speak the envelope: an nginx `502` page, a captive portal's
    /// login HTML. The status is the one thing separating "we were refused" from "the answer was
    /// gibberish", so it is read rather than discarded, and it lands in the code as `http.<status>`.
    @Test("A non-2xx with no envelope reports the status it answered with")
    func nonSuccessStatusIsReported() async throws {
        let client = Self.client(Self.http(502, "<html>502 Bad Gateway</html>"))

        do {
            _ = try await client.send(.ping)
            Issue.record("expected a failure")
        } catch let failure as CLIFailure {
            guard case let .commandFailed(error) = failure else {
                Issue.record("expected a commandFailed, got \(failure)")
                return
            }
            #expect(error.code == "http.502")
            #expect(error.message.contains("502 Bad Gateway"))
            #expect(failure.exitCode == 4)
        }
    }

    /// A 2xx this CLI cannot read really is a decoding problem, and stays one.
    @Test("A 2xx that will not decode is a decoding failure")
    func undecodableSuccess() async {
        let client = Self.client(Self.http(200, "definitely not JSON"))

        await #expect(throws: CLIFailure.undecodable("definitely not JSON")) {
            _ = try await client.send(.ping)
        }
    }

    /// Nothing answered at all — the port is closed, the host is gone. The failure names where it was
    /// pointed, because "no instance" is the single most common reason a command cannot proceed.
    @Test("A transport error is reported as unreachable, naming the base URL")
    func transportFailureIsUnreachable() async {
        // `CustomStringConvertible` as well as `LocalizedError`: `send` reports
        // `error.localizedDescription`, and on Linux that falls back to `String(describing:)` rather
        // than to `errorDescription`. Spelling both means the assertion below is about the CLI's
        // reporting rather than about which Foundation the suite is running against.
        struct Dropped: Error, LocalizedError, CustomStringConvertible {
            var description: String { "connection refused" }
            var errorDescription: String? { "connection refused" }
        }
        let client = Self.client { _ in throw Dropped() }

        do {
            _ = try await client.send(.ping)
            Issue.record("expected a failure")
        } catch let failure as CLIFailure {
            guard case let .unreachable(baseURL, underlying) = failure else {
                Issue.record("expected an unreachable, got \(failure)")
                return
            }
            #expect(baseURL.absoluteString == "http://127.0.0.1:8787")
            #expect(underlying.contains("connection refused"))
            #expect(failure.exitCode == 3)
        }
    }

    // MARK: - The token

    @Test("The token is attached as X-Mimic-Token, and omitted when there is none")
    func tokenIsAttached() async throws {
        let withToken = CapturedHeaders()
        let carrying = Self.client(token: "not-a-real-token") { request in
            withToken.record(request.allHTTPHeaderFields)
            return try await Self.http(200, #"{"ok":true,"result":{}}"#)(request)
        }
        _ = try await carrying.send(.ping)
        #expect(withToken.value[ControlAPI.tokenHeaderName] == "not-a-real-token")

        let withoutToken = CapturedHeaders()
        let bare = Self.client { request in
            withoutToken.record(request.allHTTPHeaderFields)
            return try await Self.http(200, #"{"ok":true,"result":{}}"#)(request)
        }
        _ = try await bare.send(.ping)
        #expect(withoutToken.value[ControlAPI.tokenHeaderName] == nil)
        #expect(withoutToken.value["Content-Type"] == "application/json")
    }

    // MARK: - Readiness

    /// `mimic app start` waits on this rather than sleeping a guessed number of seconds, so what
    /// counts as "up" matters. A `401` counts: the instance is serving, and reporting "not running"
    /// for what is really a token mismatch sends the user off restarting an app that is already fine.
    @Test(
        "Readiness treats 200 and 401 as up, and anything else as not",
        arguments: [(200, true), (401, true), (404, false), (500, false)]
    )
    func readinessStatuses(status: Int, expected: Bool) async {
        let client = Self.client(Self.http(status, ""))
        #expect(await client.isReachable() == expected)
    }

    @Test("A transport that throws is not reachable")
    func readinessOnATransportFailure() async {
        struct Dropped: Error {}
        let client = Self.client { _ in throw Dropped() }
        #expect(await client.isReachable() == false)
    }
}
