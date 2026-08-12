import ArgumentParser
import Foundation
import Testing
@testable import Domain
@testable import MimicCLICore

/// The CLI's contract with the caller: how arguments become commands, and what happens when they are
/// wrong. These matter more than usual here because the caller is often a program that cannot read a
/// help page.
@Suite("CLI argument parsing")
struct CLIParsingTests {

    // MARK: - Vocabularies

    @Test("HTTP methods are accepted in any casing")
    func methodsAreCaseInsensitive() throws {
        #expect(try ArgumentParsing.method("get") == .get)
        #expect(try ArgumentParsing.method("GET") == .get)
        #expect(try ArgumentParsing.method("Patch") == .patch)
    }

    @Test("An unknown method lists the valid ones")
    func unknownMethodIsHelpful() {
        do {
            _ = try ArgumentParsing.method("FETCH")
            Issue.record("expected a failure")
        } catch let failure as CLIFailure {
            #expect(failure.errorDescription?.contains("GET") == true)
            #expect(failure.exitCode == 2)
        } catch {
            Issue.record("expected a CLIFailure, got \(error)")
        }
    }

    @Test("Enum options accept kebab-case and any casing")
    func enumOptionsAreForgiving() throws {
        #expect(try ArgumentParsing.matchMode("strictSequence") == .strictSequence)
        #expect(try ArgumentParsing.matchMode("strict-sequence") == .strictSequence)
        #expect(try ArgumentParsing.matchMode("STRICTSEQUENCE") == .strictSequence)
        #expect(try ArgumentParsing.completion("restart") == .restart)
        #expect(try ArgumentParsing.unmatchedBehavior("fall-through-to-endpoints") == .fallThroughToEndpoints)
        #expect(try ArgumentParsing.resetScope("all") == .all)
    }

    @Test("Content types accept the short name or the MIME string")
    func contentTypeAliases() throws {
        #expect(try ArgumentParsing.contentType("json") == .json)
        #expect(try ArgumentParsing.contentType("application/json") == .json)
        #expect(try ArgumentParsing.contentType("text") == .plainText)
        #expect(try ArgumentParsing.contentType("text/plain") == .plainText)
        #expect(throws: CLIFailure.self) { _ = try ArgumentParsing.contentType("xml") }
    }

    // MARK: - Selectors

    @Test("An endpoint is selected by route, id, or name")
    func endpointSelector() throws {
        var selector = try EndpointSelector.parse(["GET", "/inbox"])
        #expect(try selector.resolve() == .route(.get, "/inbox"))

        let id = UUID()
        selector = try EndpointSelector.parse(["--id", id.uuidString])
        #expect(try selector.resolve() == .id(id))

        selector = try EndpointSelector.parse(["--name", "Login"])
        #expect(try selector.resolve() == .name("Login"))
    }

    @Test("Selecting nothing, or a malformed id, is a usage error")
    func endpointSelectorRejectsAmbiguity() throws {
        let empty = try EndpointSelector.parse([])
        #expect(throws: CLIFailure.self) { _ = try empty.resolve() }

        let bad = try EndpointSelector.parse(["--id", "not-a-uuid"])
        do {
            _ = try bad.resolve()
            Issue.record("expected a failure")
        } catch let failure as CLIFailure {
            #expect(failure.exitCode == 2)
        }
    }

    @Test("A step is selected by position, name, or id")
    func stepSelector() throws {
        #expect(try StepSelector.parse(["--index", "2"]).resolve() == .index(2))
        #expect(try StepSelector.parse(["--step", "Login"]).resolve() == .name("Login"))

        let id = UUID()
        #expect(try StepSelector.parse(["--step-id", id.uuidString]).resolve() == .id(id))
        #expect(throws: CLIFailure.self) { _ = try StepSelector.parse([]).resolve() }
    }

    @Test("`journey activate` with no argument means clear the selection")
    func journeySelectorAllowsEmpty() throws {
        #expect(try JourneySelector.parse([]).resolveOptional() == nil)
        #expect(try JourneySelector.parse(["Retry"]).resolveOptional() == .name("Retry"))
    }

    // MARK: - Response options

    @Test("Headers are parsed as Name:Value, preserving colons in the value")
    func headerParsing() throws {
        let options = try ResponseOptions.parse([
            "-H", "Retry-After: 30",
            "-H", "Link: <https://example.test/next>; rel=\"next\"",
        ])
        let headers = try #require(try options.resolveHeaders())
        #expect(headers["Retry-After"] == "30")
        #expect(headers["Link"] == "<https://example.test/next>; rel=\"next\"")
    }

    @Test("A malformed header is a usage error rather than a silently dropped value")
    func malformedHeader() throws {
        let options = try ResponseOptions.parse(["-H", "NoColonHere"])
        #expect(throws: CLIFailure.self) { _ = try options.resolveHeaders() }

        let empty = try ResponseOptions.parse(["-H", ": value"])
        #expect(throws: CLIFailure.self) { _ = try empty.resolveHeaders() }
    }

    @Test("A body can come from a file")
    func bodyFromFile() throws {
        let path = NSTemporaryDirectory() + "mimic-body-\(UUID().uuidString).json"
        let payload = #"{"balance":1520.44}"#
        try payload.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let options = try ResponseOptions.parse(["--body-file", path])
        #expect(try options.resolveBody() == payload)
    }

    @Test("An unreadable body file is reported with its path")
    func missingBodyFile() throws {
        let options = try ResponseOptions.parse(["--body-file", "/nonexistent/mimic/body.json"])
        do {
            _ = try options.resolveBody()
            Issue.record("expected a failure")
        } catch let failure as CLIFailure {
            #expect(failure.errorDescription?.contains("/nonexistent/mimic/body.json") == true)
            #expect(failure.exitCode == 4)
        }
    }

    @Test("An empty response option set means \"change nothing\"")
    func emptySpecIsDetectable() throws {
        let options = try ResponseOptions.parse([])
        #expect(try options.scenarioSpec() == ScenarioSpec())

        let withStatus = try ResponseOptions.parse(["--status", "500"])
        #expect(try withStatus.scenarioSpec() != ScenarioSpec())
    }

    // MARK: - Failure options

    @Test("Failure spellings map to the two transport failures")
    func failureParsing() throws {
        #expect(try FailureOption.parse(["--fail", "drop"]).resolve() == .connectionDrop)
        #expect(try FailureOption.parse(["--fail", "connection-drop"]).resolve() == .connectionDrop)
        #expect(
            try FailureOption.parse(["--fail", "timeout"]).resolve()
                == .timeout(holdMs: NetworkFailure.defaultTimeoutHoldMs)
        )
        #expect(try FailureOption.parse(["--fail", "timeout", "--hold-ms", "5000"]).resolve() == .timeout(holdMs: 5_000))
        #expect(try FailureOption.parse([]).resolve() == nil)
    }

    @Test("--hold-ms without a timeout, and unknown failure kinds, are usage errors")
    func failureMisuse() throws {
        #expect(throws: CLIFailure.self) { _ = try FailureOption.parse(["--hold-ms", "500"]).resolve() }
        #expect(throws: CLIFailure.self) { _ = try FailureOption.parse(["--fail", "drop", "--hold-ms", "500"]).resolve() }
        #expect(throws: CLIFailure.self) { _ = try FailureOption.parse(["--fail", "explode"]).resolve() }
    }

    @Test("A step cannot both respond and fail")
    func stepCannotRespondAndFail() throws {
        #expect(throws: CLIFailure.self) {
            _ = try StepBuilder.spec(
                name: nil,
                method: "GET",
                path: "/inbox",
                response: try ResponseOptions.parse(["--status", "200"]),
                failure: try FailureOption.parse(["--fail", "drop"]),
                delay: nil,
                repeatCount: nil
            )
        }
    }

    @Test("A step spec carries every option through")
    func stepSpecCarriesOptions() throws {
        let spec = try StepBuilder.spec(
            name: "Slow poll",
            method: "get",
            path: "/reports/:id",
            response: try ResponseOptions.parse(["--status", "202", "--body", "{}", "-H", "X-Trace: abc"]),
            failure: try FailureOption.parse([]),
            delay: 400,
            repeatCount: 3
        )
        #expect(spec.name == "Slow poll")
        #expect(spec.method == .get)
        #expect(spec.path == "/reports/:id")
        #expect(spec.statusCode == 202)
        #expect(spec.headers?["X-Trace"] == "abc")
        #expect(spec.delayMs == 400)
        #expect(spec.repeatCount == 3)
        #expect(spec.failure == nil)
    }

    // MARK: - Command tree

    @Test("Every documented command path parses")
    func commandTreeParses() throws {
        let invocations: [[String]] = [
            ["ping"], ["state"], ["commands"], ["reset", "--scope", "logs"],
            ["app", "start", "--headless"], ["app", "stop"], ["app", "status"],
            ["daemon", "start"], ["daemon", "stop"],
            ["server", "start", "--port", "8080"], ["server", "stop"], ["server", "status"],
            ["server", "configure", "--delay", "250"],
            ["project", "list"], ["project", "create", "Checkout", "--port", "9000"],
            ["project", "open", "Checkout"], ["project", "close"], ["project", "delete", "Checkout"],
            ["project", "rename", "New"], ["project", "duplicate", "Checkout"],
            ["project", "export", "-o", "out.json"], ["project", "import", "in.json"],
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
            ["journey", "create", "Flow", "--file", "flow.json", "--activate"],
            ["journey", "update", "Flow", "--completion", "restart"],
            ["journey", "delete", "Flow"], ["journey", "duplicate", "Flow"],
            ["journey", "templates"], ["journey", "add-template", "session-expiry", "--activate"],
            ["journey", "activate", "Flow"], ["journey", "deactivate"],
            ["journey", "restart"], ["journey", "advance"], ["journey", "status"],
            ["journey", "export", "Flow", "-o", "flow.json"],
            ["journey", "import", "flow.json", "--replace", "--activate"],
            ["journey", "step", "add", "Flow", "GET", "/a", "--status", "500"],
            ["journey", "step", "add", "Flow", "GET", "/a", "--fail", "timeout", "--hold-ms", "1000"],
            ["journey", "step", "add-batch", "Flow", "captured.json"],
            ["journey", "step", "add-batch", "Flow", "-", "--at", "0"],
            ["journey", "step", "update", "Flow", "--index", "0", "--status", "503"],
            ["journey", "step", "remove", "Flow", "--index", "1"],
            ["journey", "step", "move", "Flow", "--index", "0", "--to", "2"],
            ["log", "list", "--limit", "20"], ["log", "clear"],
        ]

        for invocation in invocations {
            #expect(throws: Never.self, "failed to parse: mimic \(invocation.joined(separator: " "))") {
                _ = try MimicCommand.parseAsRoot(invocation)
            }
        }
    }

    @Test("Global options apply to every command")
    func globalOptionsParse() throws {
        _ = try MimicCommand.parseAsRoot([
            "state", "--url", "http://127.0.0.1:9000", "--format", "text", "--pretty", "--timeout", "5",
        ])
        _ = try MimicCommand.parseAsRoot(["journey", "status", "--format", "json"])
    }

    @Test("An unknown subcommand is rejected rather than silently ignored")
    func unknownSubcommandFails() {
        #expect(throws: (any Error).self) { _ = try MimicCommand.parseAsRoot(["journey", "teleport"]) }
        #expect(throws: (any Error).self) { _ = try MimicCommand.parseAsRoot(["nonsense"]) }
    }

    @Test("Exit codes distinguish usage errors, missing instances, and failed commands")
    func exitCodeContract() {
        #expect(CLIFailure.badArgument("x").exitCode == 2)
        // A path the caller mistyped is bad usage; nothing was ever sent to Mimic.
        #expect(CLIFailure.fileUnreadable(path: "x", underlying: "y").exitCode == 2)
        #expect(CLIFailure.noInstance.exitCode == 3)
        #expect(CLIFailure.unreachable(baseURL: URL(string: "http://127.0.0.1:1")!, underlying: "x").exitCode == 3)
        #expect(CLIFailure.commandFailed(.noProjectOpen).exitCode == 4)
        // The arguments were fine and Mimic answered — just not with anything decodable.
        #expect(CLIFailure.undecodable("x").exitCode == 4)
    }

    /// The contract is only real at the process boundary, and that is where it was broken: everything
    /// above asserts `CLIFailure`, which `MimicCommand.run` never sees for a usage error. Those come
    /// from ArgumentParser, whose usage exit status is `EX_USAGE` — so these invocations exited 64
    /// while docs/CLI.md promised 2, and no test looked.
    @Test(
        "Usage errors exit 2 from the process, not just from CLIFailure",
        arguments: [
            ["nonsense"],
            ["journey", "teleport"],
            ["endpoint", "create"],
            ["server", "configure", "--port", "not-a-number"],
        ]
    )
    func usageErrorsExitTwo(arguments: [String]) async {
        #expect(await MimicCommand.run(arguments: arguments) == 2)
    }

    @Test("--help and --version are successes, not usage errors")
    func helpExitsZero() async {
        #expect(await MimicCommand.run(arguments: ["--help"]) == 0)
        #expect(await MimicCommand.run(arguments: ["journey", "--help"]) == 0)
    }

    @Test("\"No instance\" says how to start one")
    func noInstanceIsActionable() throws {
        let message = try #require(CLIFailure.noInstance.errorDescription)
        #expect(message.contains("mimic app start"))
        #expect(message.contains("mimic daemon start"))
        #expect(message.contains("MIMIC_CONTROL_URL"))
    }

    /// `JourneyBehaviorOptions.apply` used `try?`, so a misremembered value parsed to `nil`, was
    /// written over the field, and the command exited 0 reporting a change it had not made. These are
    /// the spellings someone actually reaches for.
    @Test("A misspelled enum option is rejected rather than silently dropped")
    func behaviorOptionsRejectUnknownValues() throws {
        for bad in ["sequential", "", "STRICT_SEQUENCE", "ordered per endpoint"] {
            #expect(throws: (any Error).self, "expected \"\(bad)\" to be rejected") {
                _ = try ArgumentParsing.matchMode(bad)
            }
        }
        #expect(throws: (any Error).self) { _ = try ArgumentParsing.completion("loop") }
        #expect(throws: (any Error).self) { _ = try ArgumentParsing.unmatchedBehavior("ignore") }

        var spec = JourneySpec()
        spec.matchMode = try ArgumentParsing.matchMode("strict-sequence")
        #expect(spec.matchMode == .strictSequence)
    }
}

@Suite("CLI output")
struct CLIOutputTests {

    @Test("JSON output omits the fields a result does not carry")
    func jsonIsMinimal() throws {
        let json = try ControlCoding.string(ControlResult.message("Done"))
        #expect(json == #"{"message":"Done"}"#)
    }

    @Test("Paths are not slash-escaped, so exported files stay readable")
    func pathsAreReadable() throws {
        let endpoint = Endpoint(name: "Login", method: .post, path: "/api/v1/login")
        let json = try ControlCoding.string(ControlResult(endpoint: endpoint))
        #expect(json.contains("/api/v1/login"))
        #expect(json.contains(#"\/"#) == false)
    }

    @Test("Keys are sorted, so repeated calls diff cleanly")
    func outputIsDeterministic() throws {
        let result = ControlResult(
            message: "m",
            endpoint: Endpoint(name: "n", method: .get, path: "/p")
        )
        let first = try ControlCoding.string(result)
        let second = try ControlCoding.string(result)
        #expect(first == second)
        #expect(first.firstIndex(of: "e")! < first.firstIndex(of: "m")!, "keys should be alphabetical")
    }

    @Test("Text rendering shows a journey's step sequence and its outcomes")
    func textRenderingOfAJourney() throws {
        var project = MockProject(name: "Checkout")
        _ = try ProjectCommandExecutor.apply(
            .journeyAddTemplate(templateID: "retry-after-failure", name: "Flow"),
            to: &project
        )
        let text = TextRenderer.render(ControlResult(journey: project.journeys[0]))

        #expect(text.contains("Flow"))
        #expect(text.contains("POST"))
        #expect(text.contains("/account-summary"))
        #expect(text.contains("→ 500"))
        #expect(text.contains("→ 200"))
    }

    @Test("Text rendering marks the current step and shows repeat progress")
    func textRenderingOfStatus() throws {
        var project = MockProject(name: "Checkout")
        _ = try ProjectCommandExecutor.apply(
            .journeyAddTemplate(templateID: "progressive-loading", name: "Poll"),
            to: &project
        )
        let journey = project.journeys[0]
        var state = JourneyRunState(journeyID: journey.id)
        state = state.recordingServe(of: journey.steps[0], in: journey)
        state = state.recordingServe(of: journey.steps[1], in: journey)

        let text = TextRenderer.render(
            ControlResult(journeyStatus: JourneyStatus.make(journey: journey, state: state))
        )
        #expect(text.contains("▶"), "the current step should be marked")
        #expect(text.contains("✓"), "exhausted steps should be marked")
        #expect(text.contains("1/3"), "repeat progress should be visible")
    }

    @Test("Text rendering labels transport failures, which have no status code")
    func textRenderingOfFailures() throws {
        var project = MockProject(name: "Checkout")
        _ = try ProjectCommandExecutor.apply(
            .journeyAddTemplate(templateID: "offline-to-online", name: "Offline"),
            to: &project
        )
        let text = TextRenderer.render(ControlResult(journey: project.journeys[0]))
        #expect(text.contains("connection drop"))
        #expect(text.contains("timeout after"))
    }

    @Test("Empty collections render as a sentence, not as blank output")
    func emptyCollectionsRender() {
        #expect(TextRenderer.render(ControlResult(endpoints: [])).contains("No endpoints"))
        #expect(TextRenderer.render(ControlResult(journeys: [])).contains("No journeys"))
        #expect(TextRenderer.render(ControlResult(logs: [])).contains("No requests logged"))
        #expect(TextRenderer.render(ControlResult(projects: [])).contains("No stored projects"))
        #expect(TextRenderer.render(ControlResult()) == "OK")
    }

    @Test("State rendering covers server, project, journey, and log in a few lines")
    func stateRendering() {
        let state = ControlState(
            appVersion: nil,
            mode: "headless",
            pid: 42,
            server: ServerStatusReport(
                state: "running",
                port: 8080,
                baseURL: "http://127.0.0.1:8080",
                globalDelayMs: 50
            ),
            project: ProjectSummary(
                id: UUID(),
                name: "Checkout",
                port: 8080,
                globalDelayMs: 50,
                endpointCount: 3,
                journeyCount: 2,
                activeJourneyID: nil,
                modifiedAt: Date(timeIntervalSince1970: 0)
            ),
            endpointCount: 3,
            journeyCount: 2,
            activeJourney: nil,
            requestLogCount: 7
        )
        let text = TextRenderer.render(ControlResult(state: state))
        #expect(text.contains("running on port 8080"))
        #expect(text.contains("http://127.0.0.1:8080"))
        #expect(text.contains("global delay 50ms"))
        #expect(text.contains("Checkout — 3 endpoints, 2 journeys"))
        #expect(text.contains("(none active)"))
        #expect(text.contains("7 entries"))
    }

    @Test("Long values widen a column instead of being truncated into a lie")
    func paddingNeverTruncates() {
        let long = "/a/very/long/path/that/exceeds/the/column/width"
        #expect(long.padded(to: 10).hasPrefix(long))
        #expect("short".padded(to: 10).count == 10)
    }
}

@Suite("Journey files")
struct JourneyFileTests {

    static func write(_ json: String) throws -> String {
        let path = NSTemporaryDirectory() + "mimic-journey-\(UUID().uuidString).json"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("A hand-written journey file is accepted in its simplest form")
    func readsHandWrittenSpec() throws {
        let path = try Self.write("""
        {
          "name": "Retry after failure",
          "summary": "The canonical flow",
          "steps": [
            { "name": "Login",   "method": "POST", "path": "/login",           "statusCode": 200, "body": "{}" },
            { "name": "Fails",   "method": "GET",  "path": "/account-summary", "statusCode": 500 },
            { "name": "Inbox",   "method": "GET",  "path": "/inbox",           "statusCode": 200 },
            { "name": "Recovers","method": "GET",  "path": "/account-summary", "statusCode": 200 }
          ]
        }
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let spec = try JourneyFile.readSpec(path)
        #expect(spec.name == "Retry after failure")
        #expect(spec.summary == "The canonical flow")
        #expect(spec.steps?.count == 4)
        #expect(spec.steps?[1].statusCode == 500)
    }

    @Test("Transport failures are expressible in a journey file")
    func readsFailureSteps() throws {
        let path = try Self.write("""
        {
          "name": "Offline",
          "steps": [
            { "method": "GET", "path": "/inbox", "failure": { "connectionDrop": {} } },
            { "method": "GET", "path": "/inbox", "failure": { "timeout": { "holdMs": 5000 } } }
          ]
        }
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let spec = try JourneyFile.readSpec(path)
        #expect(spec.steps?[0].failure == .connectionDrop)
        #expect(spec.steps?[1].failure == .timeout(holdMs: 5_000))
    }

    @Test("A file produced by `journey get` is also accepted")
    func readsAFullJourney() throws {
        var project = MockProject(name: "Checkout")
        _ = try ProjectCommandExecutor.apply(
            .journeyAddTemplate(templateID: "session-expiry", name: "Session"),
            to: &project
        )
        let path = try Self.write(try ControlCoding.string(project.journeys[0], pretty: true))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let spec = try JourneyFile.readSpec(path)
        #expect(spec.name == "Session")
        #expect(spec.steps?.count == 5)
    }

    @Test("A journey round-trips through a file without ids leaking in")
    func exportedSpecIsPortable() throws {
        var project = MockProject(name: "Checkout")
        _ = try ProjectCommandExecutor.apply(
            .journeyAddTemplate(templateID: "progressive-loading", name: "Poll"),
            to: &project
        )
        let original = project.journeys[0]
        let json = try ControlCoding.string(JourneyFile.spec(from: original), pretty: true)

        #expect(json.contains(original.id.uuidString) == false, "a portable file must not carry ids")

        // Recreating from the file reproduces the same behaviour, with new identities.
        var target = MockProject(name: "Other")
        let spec = try ControlCoding.decode(JourneySpec.self, from: Data(json.utf8))
        _ = try ProjectCommandExecutor.apply(.journeyCreate(name: "Poll", spec: spec), to: &target)

        let rebuilt = target.journeys[0]
        #expect(rebuilt.steps.map(\.path) == original.steps.map(\.path))
        #expect(rebuilt.steps.map(\.outcome) == original.steps.map(\.outcome))
        #expect(rebuilt.steps.map(\.repeatCount) == original.steps.map(\.repeatCount))
        #expect(rebuilt.steps.map(\.delayMs) == original.steps.map(\.delayMs))
        #expect(rebuilt.id != original.id)
    }

    @Test("Defaults are omitted from an exported file, keeping diffs small")
    func exportOmitsDefaults() throws {
        let journey = Journey(
            name: "Simple",
            steps: [
                JourneyStep(
                    name: "ok",
                    method: .get,
                    path: "/a",
                    outcome: .respond(JourneyResponse(statusCode: 200))
                )
            ]
        )
        let json = try ControlCoding.string(JourneyFile.spec(from: journey))
        #expect(json.contains("delayMs") == false)
        #expect(json.contains("repeatCount") == false)
        #expect(json.contains("headers") == false)
    }

    @Test("A file that is not a journey is rejected with its path")
    func rejectsNonJourneyFiles() throws {
        let path = try Self.write(#"{"unrelated":true}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: CLIFailure.self) { _ = try JourneyFile.readSpec(path) }
        #expect(throws: CLIFailure.self) { _ = try JourneyFile.readSpec("/nonexistent/x.json") }
    }
}

@Suite("App launching")
struct AppLauncherTests {

    @Test("MIMIC_APP_PATH is searched before the installed locations")
    func overrideComesFirst() {
        let candidates = AppLauncher.candidateBundles(
            environment: ["MIMIC_APP_PATH": "/custom/Build/Mimic.app"],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        #expect(candidates.first?.path == "/custom/Build/Mimic.app")
        #expect(candidates.contains { $0.path == "/Applications/Mimic.app" })
        #expect(candidates.contains { $0.path == "/Users/test/Applications/Mimic.app" })
    }

    @Test("A tilde in the override is expanded")
    func overrideExpandsTilde() {
        let candidates = AppLauncher.candidateBundles(environment: ["MIMIC_APP_PATH": "~/Build/Mimic.app"])
        #expect(candidates.first?.path.hasPrefix("/") == true)
        #expect(candidates.first?.path.contains("~") == false)
    }

    @Test("When no bundle exists the error lists everywhere that was tried")
    func missingBundleIsDiagnosable() {
        do {
            // Candidates are injected so the outcome does not depend on whether Mimic happens to be
            // installed on the machine running this suite.
            _ = try AppLauncher.resolveExecutable(
                environment: ["MIMIC_APP_PATH": "/nowhere/Mimic.app"],
                candidates: [
                    URL(fileURLWithPath: "/nowhere/Mimic.app"),
                    URL(fileURLWithPath: "/also-nowhere/Mimic.app"),
                ]
            )
            Issue.record("expected a failure")
        } catch let failure as CLIFailure {
            let message = failure.errorDescription ?? ""
            #expect(message.contains("/nowhere/Mimic.app"))
            #expect(message.contains("/also-nowhere/Mimic.app"))
            #expect(message.contains("MIMIC_APP_PATH"))
            #expect(failure.exitCode == 2)
        } catch {
            Issue.record("expected a CLIFailure, got \(error)")
        }
    }

    @Test("Terminating an invalid pid is refused rather than attempted")
    func refusesInvalidPid() {
        #expect(throws: CLIFailure.self) { try AppLauncher.terminate(pid: 0) }
        #expect(throws: CLIFailure.self) { try AppLauncher.terminate(pid: -5) }
    }
}
