import Foundation
import Testing
@testable import Domain
@testable import MimicCLICore

/// What `--format text` actually prints.
///
/// Every `render*` function here is a pure `ControlResult -> String`, and until this file none of
/// them was asserted anywhere: `CLIOutputTests` in `CLIParsingTests.swift` covers the journey and
/// status renderers, the empty-collection sentences, one populated state block and the padding
/// helper, and nothing else. The rest of the surface — every row a human reads out of
/// `mimic endpoint list`, `mimic scenario list`, `mimic project list`, `mimic log list`,
/// `mimic describe` — was rendered by code no test had ever run.
///
/// The expectations are whole lines rather than `contains` checks on purpose. These are column
/// layouts, and a column that silently moves is exactly the regression a substring match cannot
/// see; `padded(to:)` is the only thing holding them apart.
@Suite("CLI text rendering")
struct TextRendererTests {

    // MARK: - Endpoints

    @Test("An endpoint row carries the active scenario, the delay, and the group tag")
    func endpointRow() {
        let happy = Scenario(name: "Happy path", statusCode: 200)
        let endpoint = Endpoint(
            name: "User",
            method: .get,
            path: "/users/:id",
            scenarios: [happy],
            activeScenarioID: happy.id,
            delayMs: 250,
            groupTag: "Accounts"
        )
        #expect(
            TextRenderer.render(ControlResult(endpoint: endpoint))
                == "GET     /users/:id                              200 Happy path +250ms [Accounts]"
        )
    }

    @Test("An endpoint row names the active scenario, not the first one")
    func endpointRowFollowsTheActiveScenario() {
        let happy = Scenario(name: "Happy path", statusCode: 200)
        let broken = Scenario(name: "Server error", statusCode: 500)
        // `scenarios.first` and `scenarios.first { $0.id == activeScenarioID }` agree on every
        // endpoint whose active scenario is still the one it was created with, which is why the
        // difference has to be asserted with the *second* scenario activated.
        let endpoint = Endpoint(
            name: "User",
            path: "/users",
            scenarios: [happy, broken],
            activeScenarioID: broken.id
        )
        let text = TextRenderer.render(ControlResult(endpoint: endpoint))
        #expect(text.hasSuffix("500 Server error"))
        #expect(text.contains("Happy path") == false)
    }

    @Test("An endpoint with nothing active says so rather than rendering a blank column")
    func endpointWithoutAnActiveScenario() {
        // What `mimic endpoint create` leaves behind: the executor only sets `activeScenarioID`
        // when a scenario is added.
        let endpoint = Endpoint(name: "Sessions", method: .post, path: "/sessions")
        #expect(
            TextRenderer.render(ControlResult(endpoint: endpoint))
                == "POST    /sessions                               (no active scenario)"
        )
    }

    @Test("A GraphQL row names the operation, because the path alone identifies nothing")
    func graphqlEndpointRow() {
        let created = Scenario(name: "Created", statusCode: 201)
        let endpoint = Endpoint(
            name: "Create order",
            method: .post,
            path: "/graphql",
            scenarios: [created],
            activeScenarioID: created.id,
            graphqlOperation: "CreateOrder"
        )
        #expect(
            TextRenderer.render(ControlResult(endpoint: endpoint))
                == "POST    /graphql · CreateOrder                  201 Created"
        )
        // An empty operation is not an operation: it must not leave a dangling separator behind.
        #expect(TextRenderer.route("/graphql", "") == "/graphql")
        #expect(TextRenderer.route("/graphql", nil) == "/graphql")
    }

    @Test("A scenario row is status, name, and the content type the body will be served as")
    func scenarioRow() {
        let json = Scenario(name: "Not found", statusCode: 404)
        #expect(
            TextRenderer.render(ControlResult(scenario: json))
                == "404   Not found                 application/json"
        )
        let text = Scenario(name: "Plain", statusCode: 200, bodyContentType: .plainText)
        #expect(TextRenderer.render(ControlResult(scenario: text)).hasSuffix("text/plain"))
    }

    // MARK: - Projects

    @Test("A project row states the port and the counts")
    func projectSummaryRow() {
        let summary = ProjectSummary(
            id: UUID(),
            name: "Checkout",
            port: 8080,
            globalDelayMs: 50,
            endpointCount: 3,
            journeyCount: 2,
            activeJourneyID: nil,
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(
            TextRenderer.render(ControlResult(projects: [summary]))
                == "Checkout                    port 8080  3 endpoints, 2 journeys"
        )
    }

    @Test("The project block names the active journey only when one resolves")
    func projectBlock() {
        let flow = Journey(name: "Flow")
        var project = MockProject(
            name: "Checkout",
            serverConfiguration: ServerConfiguration(port: 9090, globalDelayMs: 50),
            endpoints: [
                Endpoint(name: "One", path: "/one"),
                Endpoint(name: "Two", path: "/two"),
                Endpoint(name: "Three", path: "/three"),
            ],
            journeys: [flow, Journey(name: "Other")]
        )
        #expect(TextRenderer.render(ControlResult(project: project)) == """
        Checkout
          port         9090
          global delay 50ms
          endpoints    3
          journeys     2
        """)

        project.activeJourneyID = flow.id
        #expect(TextRenderer.render(ControlResult(project: project)).hasSuffix("\n  active       Flow"))

        // `MockProject.activeJourney` reads an id that resolves to nothing as "no journey", and the
        // block has to say the same thing rather than printing an empty `active` row.
        project.activeJourneyID = UUID()
        #expect(TextRenderer.render(ControlResult(project: project)).contains("active") == false)
    }

    // MARK: - Server and state

    @Test("The server line shows only what the report carries")
    func serverLine() {
        let stopped = ServerStatusReport(state: "stopped", port: 8080, baseURL: nil, globalDelayMs: 0)
        let idle = TextRenderer.render(ControlResult(server: stopped))
        #expect(idle == "server       stopped on port 8080")
        // A zero delay is not a delay, and a stopped server has no base URL to point a client at.
        #expect(idle.contains("global delay") == false)
        #expect(idle.contains("(") == false)

        let running = ServerStatusReport(
            state: "running",
            port: 3000,
            baseURL: "http://127.0.0.1:3000",
            globalDelayMs: 120,
            message: "Port 8080 was busy."
        )
        #expect(
            TextRenderer.render(ControlResult(server: running))
                == "server       running on port 3000 (http://127.0.0.1:3000), global delay 120ms"
                + "\n             Port 8080 was busy."
        )
    }

    @Test("The state block says so when nothing is open, running, or active")
    func stateWithNothingOpen() {
        let state = ControlState(
            apiVersion: "v1",
            appVersion: "0.9.3",
            mode: "app",
            pid: 4242,
            server: ServerStatusReport(state: "stopped", port: 8080, baseURL: nil, globalDelayMs: 0),
            project: nil,
            endpointCount: 0,
            journeyCount: 0,
            activeJourney: nil,
            requestLogCount: 0
        )
        #expect(TextRenderer.render(ControlResult(state: state)) == """
        Mimic app (api v1, pid 4242)
        server       stopped on port 8080
        project      (none open)
        journey      (none active)
        request log  0 entries
        """)
    }

    // MARK: - Journeys

    @Test("A journey list row states the step count, the match mode, and the completion rule")
    func journeySummaryRow() {
        let journey = Journey(
            name: "Checkout flow",
            steps: [
                JourneyStep(name: "Login", method: .post, path: "/login", outcome: .respond(JourneyResponse())),
                JourneyStep(name: "Inbox", path: "/inbox", outcome: .respond(JourneyResponse())),
            ]
        )
        #expect(
            TextRenderer.render(ControlResult(journeys: [journey]))
                == "Checkout flow                 2 steps, orderedPerEndpoint, stop"
        )
    }

    @Test("A journey with no steps still renders its header and its rules")
    func journeyDetailWithNoSteps() {
        #expect(TextRenderer.render(ControlResult(journey: Journey(name: "Empty"))) == """
        Empty  (0 steps)
          match orderedPerEndpoint · on completion stop · unmatched fallThroughToEndpoints · autoAdvance true
        """)

        let described = Journey(
            name: "Empty",
            summary: "Nothing scripted yet.",
            matchMode: .strictSequence,
            completion: .restart,
            unmatchedBehavior: .notFound,
            autoAdvance: false
        )
        #expect(TextRenderer.render(ControlResult(journey: described)) == """
        Empty  (0 steps)
          Nothing scripted yet.
          match strictSequence · on completion restart · unmatched notFound · autoAdvance false
        """)
    }

    @Test("Journey steps are numbered from zero and carry their delay and repeat count")
    func journeyDetailStepLines() {
        let journey = Journey(
            name: "Flow",
            steps: [
                JourneyStep(
                    name: "Login",
                    method: .post,
                    path: "/login",
                    outcome: .respond(JourneyResponse(statusCode: 200))
                ),
                JourneyStep(
                    name: "Stalls",
                    path: "/inbox",
                    outcome: .networkFailure(.timeout(holdMs: 30_000)),
                    delayMs: 50,
                    repeatCount: 3
                ),
            ]
        )
        #expect(TextRenderer.render(ControlResult(journey: journey)) == """
        Flow  (2 steps)
          match orderedPerEndpoint · on completion stop · unmatched fallThroughToEndpoints · autoAdvance true
          0   POST    /login                                  → 200
          1   GET     /inbox                                  → timeout after 30000ms +50ms ×3
        """)
    }

    @Test("A status header names the position, and a stepless journey is not \"step 1/0\"")
    func statusHeaderPosition() {
        // Two facts this rests on, both from `JourneyStatus.make`: a fresh run is not complete, and
        // a cursor of 0 against zero steps names no step. `mimic journey create Flow --activate`
        // produces exactly this DTO, and it used to render as "step 1/0" here and as "complete" in
        // the state block — two different lies about the same journey in one CLI.
        let empty = JourneyStatus.make(journey: Journey(name: "Empty"), state: nil)
        #expect(empty.isComplete == false)
        #expect(empty.currentStepIndex == nil)
        #expect(TextRenderer.render(ControlResult(journeyStatus: empty)) == "Empty — no current step, 0 served")

        let state = ControlState(
            apiVersion: "v1",
            mode: "app",
            pid: 1,
            server: ServerStatusReport(state: "stopped", port: 8080, baseURL: nil, globalDelayMs: 0),
            project: nil,
            endpointCount: 0,
            journeyCount: 1,
            activeJourney: empty,
            requestLogCount: 0
        )
        #expect(TextRenderer.render(ControlResult(state: state)).contains("journey      Empty — no current step"))
    }

    @Test("A run in progress reports the step it is on, and a finished one reports completion")
    func statusHeaderThroughARun() {
        let first = JourneyStep(name: "One", path: "/a", outcome: .respond(JourneyResponse(statusCode: 200)))
        let second = JourneyStep(name: "Two", path: "/b", outcome: .respond(JourneyResponse(statusCode: 200)))
        let journey = Journey(name: "Flow", steps: [first, second])

        var run = JourneyRunState(journeyID: journey.id).recordingServe(of: first, in: journey)
        let midway = JourneyStatus.make(journey: journey, state: run)
        #expect(midway.isComplete == false)
        #expect(TextRenderer.render(ControlResult(journeyStatus: midway)).hasPrefix("Flow — step 2/2, 1 served"))

        run = run.recordingServe(of: second, in: journey)
        let finished = JourneyStatus.make(journey: journey, state: run)
        #expect(finished.isComplete)
        #expect(TextRenderer.render(ControlResult(journeyStatus: finished)).hasPrefix("Flow — complete, 2 served"))
    }

    @Test("A status line marks the cursor, and an outcome it cannot name renders as ?")
    func statusStepLines() {
        // Neither a status code nor a failure label: unreachable through `JourneyStatus.make`, which
        // always fills one of the two, but reachable here — the CLI decodes this DTO from whatever
        // instance answered, and `renderStatus` is the only thing between that and a crash-free line.
        let unknown = JourneyStepProgress(
            id: UUID(),
            index: 0,
            name: "Mystery",
            method: .get,
            path: "/a",
            statusCode: nil,
            failure: nil,
            repeatCount: 1,
            servedCount: 0,
            isExhausted: false,
            isCurrent: true
        )
        let pending = JourneyStepProgress(
            id: UUID(),
            index: 1,
            name: "Later",
            method: .get,
            path: "/b",
            statusCode: 200,
            failure: nil,
            repeatCount: 1,
            servedCount: 0,
            isExhausted: false,
            isCurrent: false
        )
        let status = JourneyStatus(
            journeyID: UUID(),
            journeyName: "Flow",
            isComplete: false,
            totalSteps: 2,
            totalServed: 0,
            currentStepIndex: 0,
            steps: [unknown, pending]
        )
        #expect(TextRenderer.render(ControlResult(journeyStatus: status)) == """
        Flow — step 1/2, 0 served
          ▶ 0   GET     /a                                      → ?
            1   GET     /b                                      → 200
        """)
    }

    // MARK: - Request log

    @Test("A log row is the entry's own timestamp, the route, the result, and what answered it")
    func logRows() throws {
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        let served = RequestLog(
            timestamp: stamped,
            method: .get,
            path: "/health",
            responseStatusCode: 200,
            outcome: .endpoint
        )
        let row = TextRenderer.render(ControlResult(logs: [served]))

        // The stamp is the entry's, in a form something can parse back — not "now", which is what a
        // renderer reaching for `Date()` instead of `log.timestamp` would print and no substring
        // check would notice. Tolerance rather than equality because ISO-8601 drops sub-second parts.
        let parsed = try #require(ISO8601DateFormatter().date(from: String(row.prefix(while: { $0 != " " }))))
        #expect(abs(parsed.timeIntervalSince(stamped)) < 1)
        #expect(row.hasSuffix("GET     /health                           200   Endpoint"))

        // A transport failure has no status code, and the outcome column is the whole point of the
        // row: a journey answering must never read like a missing mock.
        let failed = RequestLog(
            timestamp: stamped,
            method: .post,
            path: "/checkout",
            failureLabel: "timeout(30000ms)",
            outcome: .journey
        )
        #expect(
            TextRenderer.render(ControlResult(logs: [failed]))
                .hasSuffix("POST    /checkout                         timeout(30000ms) Journey")
        )

        let missing = RequestLog(timestamp: stamped, method: .get, path: "/missing", outcome: .unmatched)
        #expect(
            TextRenderer.render(ControlResult(logs: [missing]))
                .hasSuffix("GET     /missing                          —     Unmatched")
        )

        // Rows are one per line; only *sections* get a blank line between them.
        let both = TextRenderer.render(ControlResult(logs: [served, missing]))
        #expect(both.components(separatedBy: "\n").count == 2)
    }

    // MARK: - Catalogs

    @Test("A template and a command each render as a titled line and an indented second line")
    func catalogRows() {
        let template = JourneyTemplates.Template(
            id: "retry-after-failure",
            title: "Retry after failure",
            summary: "A call fails once, then succeeds.",
            spec: JourneySpec()
        )
        #expect(
            TextRenderer.render(ControlResult(journeyTemplates: [template]))
                == "retry-after-failure     Retry after failure"
                + "\n                        A call fails once, then succeeds."
        )

        let descriptor = CommandDescriptor(
            name: "journeyActivate",
            summary: "Activate a journey.",
            parameters: ["journey"],
            cli: "mimic journey activate <name>"
        )
        #expect(
            TextRenderer.render(ControlResult(commands: [descriptor]))
                == "journeyActivate       Activate a journey."
                + "\n                      mimic journey activate <name>"
        )
    }

    // MARK: - Composition

    @Test("Sections are separated by a blank line and the message comes last")
    func sectionsAndMessageOrder() {
        // `message` is the first field of `ControlResult` and the last thing rendered, which is what
        // lets a human read the confirmation off the bottom of the output rather than hunting for it
        // above a table.
        let result = ControlResult(
            message: "Created endpoint \"Login\".",
            endpoint: Endpoint(name: "Login", method: .post, path: "/login")
        )
        let sections = TextRenderer.render(result).components(separatedBy: "\n\n")
        #expect(sections.count == 2)
        #expect(sections.first?.hasPrefix("POST    /login") == true)
        #expect(sections.last == "Created endpoint \"Login\".")
    }

    @Test("A value exactly as wide as its column still gets a separator")
    func paddingAtTheColumnWidth() {
        // The boundary `count >= width` guards: at exactly the column width a value would otherwise
        // butt straight against the next column, so `GET /a-40-character-path200 Happy path` is one
        // off-by-one away.
        #expect("0123456789".padded(to: 10) == "0123456789 ")
        #expect("01234567890".padded(to: 10) == "01234567890 ")
        #expect("abc".padded(to: 6) == "abc   ")
    }
}

/// The half of `Output` that is not formatting: what never reaches stdout, and what the process
/// exits with.
///
/// The stdout/stderr split itself is **not assertable in this process**. `emit` and `emitMessage`
/// call `print`, `writeError` writes to `FileHandle.standardError`, and capturing either means
/// `dup2`-ing over a process-global file descriptor — which Swift Testing's parallel execution makes
/// unsafe, since every other suite in this target is writing to the same two descriptors at the same
/// time. What *is* assertable in-process is the rule underneath it: a command that failed throws
/// before it can print anything at all, so nothing but a payload ever reaches stdout.
@Suite("CLI output contract")
struct OutputContractTests {

    @Test("A failed response never reaches stdout — it throws with the command's own error")
    func emitRejectsAFailedResponse() {
        do {
            try Output(format: .text).emit(.failure(.noProjectOpen))
            Issue.record("expected a failure")
        } catch let failure as CLIFailure {
            #expect(failure == .commandFailed(.noProjectOpen))
            #expect(failure.exitCode == 4)
        } catch {
            Issue.record("expected a CLIFailure, got \(error)")
        }
    }

    @Test("An ok response carrying no result is a failure, not an empty success")
    func emitRejectsAnOkResponseWithNoResult() {
        // `ok` and `result` are separate fields on the wire, so "true, and nothing" is a shape a
        // caller can receive. Printing an empty line and exiting 0 for it would tell a script the
        // command worked.
        do {
            try Output(format: .json).emit(ControlResponse(ok: true, result: nil))
            Issue.record("expected a failure")
        } catch let failure as CLIFailure {
            #expect(failure.exitCode == 4)
            guard case let .commandFailed(error) = failure else {
                Issue.record("expected a commandFailed, got \(failure)")
                return
            }
            #expect(error.code == "internal.failure")
        } catch {
            Issue.record("expected a CLIFailure, got \(error)")
        }
    }

    @Test("An error that is not a CLIFailure exits non-zero")
    func exitCodeForAForeignError() {
        // Nothing in `Sources` calls this today — `MimicCommand.run` reads `CLIFailure.exitCode`
        // directly and hands everything else to ArgumentParser's own `exitCode(for:)` — so this
        // assertion is the only thing holding the mapping for the next caller that reaches for it.
        #expect(Output.exitCode(for: CLIFailure.noInstance) == 3)
        #expect(Output.exitCode(for: CLIFailure.commandFailed(.noProjectOpen)) == 4)
        #expect(Output.exitCode(for: ControlError.noProjectOpen) == 1)
    }
}

/// The JSON path's documented properties, beyond the three `CLIOutputTests` already pins (a
/// message-only result encodes minimally, slashes are not escaped, two encodes of one value match).
@Suite("CLI JSON output")
struct JSONOutputTests {

    /// Fails naming the pair that is out of order, which `a < b` on its own does not.
    private func expectSorted(
        _ keys: [String],
        in json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        var previous: (key: String, index: String.Index)?
        for key in keys {
            let found = try #require(
                json.range(of: "\"\(key)\"")?.lowerBound,
                "\(key) is missing from \(json)",
                sourceLocation: sourceLocation
            )
            if let previous {
                #expect(
                    previous.index < found,
                    "\(previous.key) must be encoded before \(key)",
                    sourceLocation: sourceLocation
                )
            }
            previous = (key: key, index: found)
        }
    }

    @Test("--pretty adds whitespace and nothing else: keys stay sorted, slashes stay readable")
    func prettyPrintingKeepsTheContract() throws {
        let endpoint = Endpoint(name: "Login", method: .post, path: "/api/v1/login")
        let compact = try ControlCoding.string(ControlResult(endpoint: endpoint))
        let pretty = try ControlCoding.string(ControlResult(endpoint: endpoint), pretty: true)

        #expect(compact.contains("\n") == false)
        #expect(pretty.contains("\n"))
        #expect(pretty.contains("/api/v1/login"))
        #expect(pretty.contains(#"\/"#) == false)

        // Sorted at every level and in both forms. `--pretty` is the one a human puts in a pull
        // request, so it is the one whose key order has to be stable.
        let keys = ["delayMs", "id", "method", "name", "path", "scenarios"]
        try expectSorted(keys, in: compact)
        try expectSorted(keys, in: pretty)
    }

    @Test("A field a value does not carry is absent, not null")
    func absentFieldsAreOmittedAtEveryLevel() throws {
        let bare = Endpoint(name: "Login", method: .post, path: "/login")
        let json = try ControlCoding.string(ControlResult(endpoint: bare))
        #expect(json.contains("null") == false)
        #expect(json.contains("groupTag") == false)
        #expect(json.contains("graphqlOperation") == false)
        #expect(json.contains("activeScenarioID") == false)

        // The other half, without which the three checks above pass for a result that encodes
        // nothing at all: the same keys appear the moment the endpoint carries them.
        let tagged = Endpoint(
            name: "Login",
            method: .post,
            path: "/login",
            groupTag: "Auth",
            graphqlOperation: "SignIn"
        )
        let full = try ControlCoding.string(ControlResult(endpoint: tagged))
        #expect(full.contains(#""groupTag":"Auth""#))
        #expect(full.contains(#""graphqlOperation":"SignIn""#))
    }
}
