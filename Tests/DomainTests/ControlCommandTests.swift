import Foundation
import Testing
@testable import Domain

@Suite("Control command execution")
struct ControlCommandExecutionTests {

    /// Applies a command and returns the mutated project plus the outcome, failing the test if the
    /// command turns out to be host-scoped.
    static func apply(
        _ command: ControlCommand,
        to project: MockProject,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (project: MockProject, outcome: ProjectCommandOutcome) {
        var copy = project
        let outcome = try ProjectCommandExecutor.apply(command, to: &copy)
        let unwrapped = try #require(outcome, "expected a project-scoped command", sourceLocation: sourceLocation)
        return (copy, unwrapped)
    }

    static var project: MockProject {
        MockProject(name: "Checkout")
    }

    // MARK: - Endpoints

    @Test("Creating an endpoint gives it an active default scenario so it answers immediately")
    func endpointCreateIsImmediatelyServable() throws {
        let (project, outcome) = try Self.apply(
            .endpointCreate(name: "Login", method: .post, path: "/login", spec: nil),
            to: Self.project
        )

        let endpoint = try #require(project.endpoints.first)
        #expect(endpoint.name == "Login")
        #expect(endpoint.method == .post)
        #expect(endpoint.activeScenarioID == endpoint.scenarios.first?.id)
        #expect(outcome.didMutate)
    }

    @Test("An endpoint created without a name is named after its route")
    func endpointCreateDefaultsName() throws {
        let (project, _) = try Self.apply(
            .endpointCreate(name: nil, method: .get, path: "/inbox", spec: nil),
            to: Self.project
        )
        #expect(project.endpoints.first?.name == "GET /inbox")
    }

    @Test("Endpoints resolve by route, so callers never need to track UUIDs")
    func endpointsResolveByRoute() throws {
        var project = Self.project
        project = try Self.apply(.endpointCreate(name: nil, method: .get, path: "/inbox", spec: nil), to: project).project
        project = try Self.apply(.endpointCreate(name: nil, method: .post, path: "/inbox", spec: nil), to: project).project

        let (updated, _) = try Self.apply(
            .endpointUpdate(endpoint: .route(.post, "/inbox"), spec: EndpointSpec(delayMs: 750)),
            to: project
        )

        #expect(updated.endpoints.first { $0.method == .post }?.delayMs == 750)
        #expect(updated.endpoints.first { $0.method == .get }?.delayMs == 0)
    }

    @Test("Route lookup ignores casing and trailing slashes")
    func routeLookupIsForgiving() throws {
        let project = try Self.apply(
            .endpointCreate(name: nil, method: .get, path: "/Account-Summary", spec: nil),
            to: Self.project
        ).project

        #expect(project.endpoint(matching: .route(.get, "/account-summary/")) != nil)
    }

    @Test("An unknown endpoint reference fails with a stable, greppable code")
    func unknownEndpointFails() {
        #expect(throws: ControlError.self) {
            _ = try Self.apply(.endpointDelete(endpoint: .route(.get, "/nope")), to: Self.project)
        }

        do {
            _ = try Self.apply(.endpointDelete(endpoint: .route(.get, "/nope")), to: Self.project)
        } catch let error as ControlError {
            #expect(error.code == "endpoint.notFound")
            #expect(error.details?["path"] == "/nope")
        } catch {
            Issue.record("expected a ControlError, got \(error)")
        }
    }

    @Test("A duplicated endpoint gets fresh scenario ids so edits do not bleed back")
    func duplicateEndpointIsIndependent() throws {
        var project = try Self.apply(
            .endpointCreate(name: "Login", method: .post, path: "/login", spec: nil),
            to: Self.project
        ).project
        project = try Self.apply(.endpointDuplicate(endpoint: .route(.post, "/login")), to: project).project

        #expect(project.endpoints.count == 2)
        let originalScenarioIDs = Set(project.endpoints[0].scenarios.map(\.id))
        let copyScenarioIDs = Set(project.endpoints[1].scenarios.map(\.id))
        #expect(originalScenarioIDs.isDisjoint(with: copyScenarioIDs))
        #expect(project.endpoints[1].activeScenarioID != nil)
    }

    @Test("An empty group tag clears the group, since a shell cannot pass JSON null")
    func emptyGroupTagClearsTheGroup() throws {
        var project = try Self.apply(
            .endpointCreate(name: nil, method: .get, path: "/inbox", spec: EndpointSpec(groupTag: "Mail")),
            to: Self.project
        ).project
        #expect(project.endpoints[0].groupTag == "Mail")

        project = try Self.apply(
            .endpointUpdate(endpoint: .route(.get, "/inbox"), spec: EndpointSpec(groupTag: "")),
            to: project
        ).project
        #expect(project.endpoints[0].groupTag == nil)
    }

    @Test("Invalid paths and status codes are rejected before they reach the server")
    func validationRejectsBadInput() {
        #expect(throws: ControlError.self) {
            _ = try Self.apply(.endpointCreate(name: nil, method: .get, path: "no-leading-slash", spec: nil), to: Self.project)
        }
        #expect(throws: ControlError.self) {
            _ = try Self.apply(.serverConfigure(port: 99_999, globalDelayMs: nil), to: Self.project)
        }
    }

    // MARK: - Scenarios

    @Test("Deleting the active scenario promotes another so the endpoint keeps answering")
    func deletingActiveScenarioPromotesAnother() throws {
        var project = try Self.apply(
            .endpointCreate(name: nil, method: .get, path: "/inbox", spec: nil),
            to: Self.project
        ).project
        project = try Self.apply(
            .scenarioCreate(endpoint: .route(.get, "/inbox"), name: "Empty", spec: ScenarioSpec(statusCode: 204)),
            to: project
        ).project

        let activeName = project.endpoints[0].scenarios
            .first { $0.id == project.endpoints[0].activeScenarioID }?.name
        #expect(activeName == "Default")

        project = try Self.apply(
            .scenarioDelete(endpoint: .route(.get, "/inbox"), scenario: .name("Default")),
            to: project
        ).project

        #expect(project.endpoints[0].scenarios.count == 1)
        #expect(project.endpoints[0].activeScenarioID == project.endpoints[0].scenarios[0].id)
    }

    @Test("Activating a scenario by name switches the live response")
    func activateScenarioByName() throws {
        var project = try Self.apply(
            .endpointCreate(name: nil, method: .get, path: "/inbox", spec: nil),
            to: Self.project
        ).project
        project = try Self.apply(
            .scenarioCreate(endpoint: .route(.get, "/inbox"), name: "Server error", spec: ScenarioSpec(statusCode: 500)),
            to: project
        ).project
        project = try Self.apply(
            .scenarioActivate(endpoint: .route(.get, "/inbox"), scenario: .name("server error")),
            to: project
        ).project

        let active = project.endpoints[0].scenarios.first { $0.id == project.endpoints[0].activeScenarioID }
        #expect(active?.statusCode == 500)
    }

    // MARK: - Journeys

    @Test("A journey can be created whole from a spec, which is how a journey file is imported")
    func journeyCreateFromSpec() throws {
        let spec = JourneySpec(
            summary: "Retry flow",
            completion: .restart,
            steps: [
                JourneyStepSpec(name: "Login", method: .post, path: "/login", statusCode: 200),
                JourneyStepSpec(method: .get, path: "/account-summary", statusCode: 500),
            ]
        )
        let (project, _) = try Self.apply(.journeyCreate(name: "Retry", spec: spec), to: Self.project)

        let journey = try #require(project.journeys.first)
        #expect(journey.name == "Retry")
        #expect(journey.summary == "Retry flow")
        #expect(journey.completion == .restart)
        #expect(journey.steps.count == 2)
        // An unnamed step is labelled by position and route so a status listing stays readable.
        #expect(journey.steps[1].name == "Step 2: GET /account-summary")
        #expect(journey.steps[1].outcome == .respond(JourneyResponse(statusCode: 500)))
    }

    @Test("Several steps are added as one change, in the order given")
    func journeyStepsAddedAsOneChange() throws {
        var project = try Self.apply(.journeyCreate(name: "Flow", spec: nil), to: Self.project).project

        project = try Self.apply(
            .journeyStepsAdd(
                journey: .name("Flow"),
                steps: ["/one", "/two"].map { JourneyStepSpec(name: $0, method: .get, path: $0, statusCode: 200) },
                atIndex: nil
            ),
            to: project
        ).project
        #expect(project.journeys[0].steps.map(\.name) == ["/one", "/two"])

        // Inserting puts the whole batch at the index, still in order — not reversed, which is what
        // inserting them one at a time at a fixed index would do.
        project = try Self.apply(
            .journeyStepsAdd(
                journey: .name("Flow"),
                steps: ["/a", "/b"].map { JourneyStepSpec(name: $0, method: .get, path: $0, statusCode: 200) },
                atIndex: 0
            ),
            to: project
        ).project
        #expect(project.journeys[0].steps.map(\.name) == ["/a", "/b", "/one", "/two"])
    }

    @Test("A bad step in the batch leaves the journey untouched")
    func journeyStepsAddIsAtomic() throws {
        var project = try Self.apply(.journeyCreate(name: "Flow", spec: nil), to: Self.project).project
        project = try Self.apply(
            .journeyStepAdd(
                journey: .name("Flow"),
                step: JourneyStepSpec(name: "/existing", method: .get, path: "/existing", statusCode: 200),
                atIndex: nil
            ),
            to: project
        ).project

        // The second step has no path, so it cannot be built. The first must not survive: a partial
        // append would leave a journey nobody asked for and no error explaining half of it.
        #expect(throws: (any Error).self) {
            _ = try ProjectCommandExecutor.apply(
                .journeyStepsAdd(
                    journey: .name("Flow"),
                    steps: [
                        JourneyStepSpec(name: "/good", method: .get, path: "/good", statusCode: 200),
                        JourneyStepSpec(name: "/bad", method: .get, path: nil, statusCode: 200),
                    ],
                    atIndex: nil
                ),
                to: &project
            )
        }
        #expect(project.journeys[0].steps.map(\.name) == ["/existing"])
    }

    @Test("Steps can be appended, inserted, moved, and removed by index")
    func journeyStepEditing() throws {
        var project = try Self.apply(.journeyCreate(name: "Flow", spec: nil), to: Self.project).project

        for path in ["/one", "/two", "/three"] {
            project = try Self.apply(
                .journeyStepAdd(
                    journey: .name("Flow"),
                    step: JourneyStepSpec(name: path, method: .get, path: path, statusCode: 200),
                    atIndex: nil
                ),
                to: project
            ).project
        }
        #expect(project.journeys[0].steps.map(\.name) == ["/one", "/two", "/three"])

        project = try Self.apply(
            .journeyStepAdd(
                journey: .name("Flow"),
                step: JourneyStepSpec(name: "/zero", method: .get, path: "/zero", statusCode: 200),
                atIndex: 0
            ),
            to: project
        ).project
        #expect(project.journeys[0].steps.map(\.name) == ["/zero", "/one", "/two", "/three"])

        project = try Self.apply(
            .journeyStepMove(journey: .name("Flow"), step: .index(0), toIndex: 2),
            to: project
        ).project
        #expect(project.journeys[0].steps.map(\.name) == ["/one", "/two", "/zero", "/three"])

        project = try Self.apply(
            .journeyStepRemove(journey: .name("Flow"), step: .name("/two")),
            to: project
        ).project
        #expect(project.journeys[0].steps.map(\.name) == ["/one", "/zero", "/three"])
    }

    @Test("An out-of-range step index is a clear error, not a crash")
    func stepIndexOutOfRange() {
        #expect(throws: ControlError.self) {
            var project = Self.project
            project.journeys = [Journey(name: "Flow")]
            _ = try ProjectCommandExecutor.apply(
                .journeyStepRemove(journey: .name("Flow"), step: .index(7)),
                to: &project
            )
        }
    }

    @Test("Updating a step's status leaves its body alone")
    func stepUpdateMergesResponseFields() throws {
        var project = try Self.apply(
            .journeyCreate(
                name: "Flow",
                spec: JourneySpec(steps: [
                    JourneyStepSpec(name: "Summary", method: .get, path: "/account-summary", statusCode: 200, body: #"{"balance":10}"#)
                ])
            ),
            to: Self.project
        ).project

        project = try Self.apply(
            .journeyStepUpdate(journey: .name("Flow"), step: .index(0), spec: JourneyStepSpec(statusCode: 503)),
            to: project
        ).project

        guard case let .respond(response) = project.journeys[0].steps[0].outcome else {
            Issue.record("expected a respond outcome")
            return
        }
        #expect(response.statusCode == 503)
        #expect(response.body == #"{"balance":10}"#, "a status-only edit must not discard the body")
    }

    @Test("Setting a failure converts a responding step, and setting a status converts it back")
    func stepOutcomeConversion() throws {
        var project = try Self.apply(
            .journeyCreate(
                name: "Flow",
                spec: JourneySpec(steps: [JourneyStepSpec(method: .get, path: "/inbox", statusCode: 200)])
            ),
            to: Self.project
        ).project

        project = try Self.apply(
            .journeyStepUpdate(
                journey: .name("Flow"),
                step: .index(0),
                spec: JourneyStepSpec(failure: .timeout(holdMs: 2_000))
            ),
            to: project
        ).project
        #expect(project.journeys[0].steps[0].outcome == .networkFailure(.timeout(holdMs: 2_000)))

        project = try Self.apply(
            .journeyStepUpdate(journey: .name("Flow"), step: .index(0), spec: JourneyStepSpec(statusCode: 201)),
            to: project
        ).project
        #expect(project.journeys[0].steps[0].outcome == .respond(JourneyResponse(statusCode: 201)))
    }

    @Test("Deleting the active journey clears the selection rather than dangling")
    func deletingActiveJourneyClearsSelection() throws {
        var project = try Self.apply(.journeyCreate(name: "Flow", spec: nil), to: Self.project).project
        project.activeJourneyID = project.journeys[0].id
        #expect(project.activeJourney != nil)

        project = try Self.apply(.journeyDelete(journey: .name("Flow")), to: project).project
        #expect(project.activeJourneyID == nil)
        #expect(project.activeJourney == nil)
    }

    @Test("A dangling active id reads as no journey instead of failing")
    func danglingActiveJourneyIDIsInert() {
        var project = Self.project
        project.activeJourneyID = UUID()
        #expect(project.activeJourney == nil)
    }

    @Test("Journey steps must be valid before they are stored")
    func journeyStepValidation() {
        #expect(throws: ControlError.self) {
            _ = try Self.apply(
                .journeyCreate(name: "Bad", spec: JourneySpec(steps: [JourneyStepSpec(method: .get, path: "inbox")])),
                to: Self.project
            )
        }
        #expect(throws: ControlError.self) {
            _ = try Self.apply(
                .journeyCreate(
                    name: "Bad",
                    spec: JourneySpec(steps: [JourneyStepSpec(method: .get, path: "/inbox", statusCode: 999)])
                ),
                to: Self.project
            )
        }
        #expect(throws: ControlError.self) {
            _ = try Self.apply(
                .journeyCreate(
                    name: "Bad",
                    spec: JourneySpec(steps: [JourneyStepSpec(method: .get, path: "/inbox", repeatCount: 0)])
                ),
                to: Self.project
            )
        }
    }

    @Test("Multiple journeys coexist and are addressed independently")
    func multipleJourneysCoexist() throws {
        var project = Self.project
        for name in ["Happy path", "Payment retry", "Session expiry"] {
            project = try Self.apply(.journeyCreate(name: name, spec: nil), to: project).project
        }
        #expect(project.journeys.count == 3)
        #expect(project.journey(matching: .name("payment retry"))?.name == "Payment retry")
        #expect(project.journey(matching: .name("nope")) == nil)
    }

    // MARK: - Templates

    @Test("Every built-in template instantiates into a valid journey")
    func allTemplatesInstantiate() throws {
        for template in JourneyTemplates.all {
            let (project, _) = try Self.apply(
                .journeyAddTemplate(templateID: template.id, name: nil),
                to: Self.project
            )
            let journey = try #require(project.journeys.first, "template \(template.id) produced no journey")
            #expect(journey.name == template.title)
            #expect(journey.steps.isEmpty == false, "template \(template.id) has no steps")
        }
    }

    @Test("The template library covers every scenario named in the product goal")
    func templateLibraryIsComplete() {
        let ids = Set(JourneyTemplates.all.map(\.id))
        let required: Set<String> = [
            "retry-after-failure",
            "payment-retry",
            "session-expiry",
            "mfa-challenge",
            "maintenance-window",
            "progressive-loading",
            "offline-to-online",
            "feature-flag-rollout",
            "edge-case-responses",
        ]
        #expect(required.isSubset(of: ids))
    }

    @Test("The canonical template reproduces the flow from the goal, step for step")
    func canonicalTemplateMatchesTheGoal() throws {
        let (project, _) = try Self.apply(
            .journeyAddTemplate(templateID: "retry-after-failure", name: "Goal flow"),
            to: Self.project
        )
        let journey = try #require(project.journeys.first)

        #expect(journey.name == "Goal flow")
        #expect(journey.steps.map { "\($0.method.rawValue) \($0.path)" } == [
            "POST /login",
            "GET /account-summary",
            "GET /inbox",
            "GET /account-summary",
        ])
        #expect(journey.steps.map(\.outcome.observedStatusCode) == [200, 500, 200, 200])
    }

    @Test("The maintenance template holds its state instead of advancing")
    func maintenanceTemplateHoldsState() throws {
        let (project, _) = try Self.apply(
            .journeyAddTemplate(templateID: "maintenance-window", name: nil),
            to: Self.project
        )
        #expect(project.journeys[0].autoAdvance == false)
    }

    @Test("An unknown template id lists the valid ones")
    func unknownTemplateIsHelpful() {
        do {
            _ = try Self.apply(.journeyAddTemplate(templateID: "nope", name: nil), to: Self.project)
            Issue.record("expected a failure")
        } catch let error as ControlError {
            #expect(error.code == "journeyTemplate.notFound")
            #expect(error.message.contains("retry-after-failure"))
        } catch {
            Issue.record("expected a ControlError, got \(error)")
        }
    }

    // MARK: - Host-scoped commands

    @Test("Host-scoped commands are passed through, not silently swallowed")
    func hostScopedCommandsReturnNil() throws {
        var project = Self.project
        for command: ControlCommand in [
            .ping, .state, .serverStart(port: nil), .serverStop, .serverStatus,
            .projectList, .projectClose, .journeyActivate(journey: nil), .journeyRestart,
            .journeyAdvance, .journeyStatus, .logList(limit: nil, unmatchedOnly: nil), .logClear,
            .reset(scope: .all), .describeCommands,
        ] {
            #expect(try ProjectCommandExecutor.apply(command, to: &project) == nil, "\(command) should be host-scoped")
        }
    }

    @Test("Read-only commands report that they changed nothing, so hosts skip persisting")
    func readsDoNotClaimMutation() throws {
        let project = try Self.apply(
            .endpointCreate(name: nil, method: .get, path: "/inbox", spec: nil),
            to: Self.project
        ).project

        #expect(try Self.apply(.endpointList, to: project).outcome.didMutate == false)
        #expect(try Self.apply(.journeyList, to: project).outcome.didMutate == false)
        #expect(try Self.apply(.journeyTemplateList, to: project).outcome.didMutate == false)
        #expect(try Self.apply(.scenarioList(endpoint: .route(.get, "/inbox")), to: project).outcome.didMutate == false)
    }
}

@Suite("Control wire format")
struct ControlWireFormatTests {

    static func json(_ command: ControlCommand) throws -> String {
        try ControlCoding.string(command)
    }

    @Test("Commands encode as a single-key object named after the case")
    func commandShapeIsStable() throws {
        #expect(try Self.json(.serverStop) == #"{"serverStop":{}}"#)
        #expect(try Self.json(.reset(scope: .all)) == #"{"reset":{"scope":"all"}}"#)
        #expect(
            try Self.json(.endpointCreate(name: "Login", method: .post, path: "/login", spec: nil))
                == #"{"endpointCreate":{"method":"POST","name":"Login","path":"/login"}}"#
        )
    }

    @Test("References encode as flat objects an agent can hand-write")
    func referencesAreFlat() throws {
        #expect(
            try Self.json(.journeyActivate(journey: .name("Retry after failure")))
                == #"{"journeyActivate":{"journey":{"name":"Retry after failure"}}}"#
        )
        #expect(
            try Self.json(.endpointDelete(endpoint: .route(.get, "/inbox")))
                == #"{"endpointDelete":{"endpoint":{"method":"GET","path":"/inbox"}}}"#
        )
    }

    @Test("Every command round-trips through JSON unchanged")
    func commandsRoundTrip() throws {
        let commands: [ControlCommand] = [
            .ping, .describeCommands, .state, .reset(scope: .journey),
            .projectList, .projectCreate(name: "Checkout", port: 9090),
            .projectOpen(project: .name("Checkout")), .projectClose,
            .projectDelete(project: .id(UUID())), .projectRename(name: "Renamed"),
            .projectDuplicate(project: .name("Checkout")), .projectExport(project: nil),
            .projectImport(project: MockProject(name: "Imported"), activate: true),
            .serverStart(port: 8081), .serverStop, .serverStatus,
            .serverConfigure(port: 8080, globalDelayMs: 250),
            .endpointList, .endpointGet(endpoint: .route(.get, "/a")),
            .endpointCreate(name: nil, method: .put, path: "/a", spec: EndpointSpec(delayMs: 5, groupTag: "G")),
            .endpointUpdate(endpoint: .id(UUID()), spec: EndpointSpec(path: "/b")),
            .endpointDelete(endpoint: .name("A")), .endpointDuplicate(endpoint: .route(.get, "/a")),
            .scenarioList(endpoint: .route(.get, "/a")),
            .scenarioCreate(endpoint: .route(.get, "/a"), name: "S", spec: ScenarioSpec(statusCode: 201)),
            .scenarioUpdate(endpoint: .route(.get, "/a"), scenario: .name("S"), spec: ScenarioSpec(body: "{}")),
            .scenarioDelete(endpoint: .route(.get, "/a"), scenario: .id(UUID())),
            .scenarioActivate(endpoint: .route(.get, "/a"), scenario: .name("S")),
            .journeyList, .journeyGet(journey: .name("J")),
            .journeyCreate(name: "J", spec: JourneySpec(steps: [JourneyStepSpec(method: .get, path: "/a", statusCode: 200)])),
            .journeyTemplateList, .journeyAddTemplate(templateID: "session-expiry", name: nil),
            .journeyUpdate(journey: .name("J"), spec: JourneySpec(matchMode: .strictSequence)),
            .journeyDelete(journey: .name("J")), .journeyDuplicate(journey: .name("J")),
            .journeyStepAdd(journey: .name("J"), step: JourneyStepSpec(method: .get, path: "/a", failure: .connectionDrop), atIndex: 2),
            .journeyStepsAdd(
                journey: .name("J"),
                steps: [
                    JourneyStepSpec(method: .get, path: "/a", statusCode: 500),
                    JourneyStepSpec(method: .get, path: "/a", statusCode: 200, repeatCount: 3),
                ],
                atIndex: nil
            ),
            .journeyStepUpdate(journey: .name("J"), step: .index(0), spec: JourneyStepSpec(statusCode: 500)),
            .journeyStepRemove(journey: .name("J"), step: .index(1)),
            .journeyStepMove(journey: .name("J"), step: .index(0), toIndex: 3),
            .journeyActivate(journey: nil), .journeyRestart, .journeyAdvance, .journeyStatus,
            .logList(limit: 50, unmatchedOnly: true), .logClear,
        ]

        for command in commands {
            let data = try JSONEncoder().encode(command)
            let decoded = try JSONDecoder().decode(ControlCommand.self, from: data)
            #expect(decoded == command, "round-trip changed \(command)")
        }
    }

    @Test("Network failures encode readably enough to hand-write in a journey file")
    func networkFailureShape() throws {
        let drop = try ControlCoding.string(NetworkFailure.connectionDrop)
        let hang = try ControlCoding.string(NetworkFailure.timeout(holdMs: 5_000))
        #expect(drop == #"{"connectionDrop":{}}"#)
        #expect(hang == #"{"timeout":{"holdMs":5000}}"#)
    }

    @Test("Successful results omit every field they do not carry")
    func resultsOmitUnusedFields() throws {
        let response = ControlResponse.success(.message("Done"))
        let json = try ControlCoding.string(response)
        #expect(json == #"{"ok":true,"result":{"message":"Done"}}"#)
    }

    @Test("Failures carry a code a script can branch on without parsing English")
    func errorsAreMachineReadable() throws {
        let response = ControlResponse.failure(.noProjectOpen)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: data)
        #expect(decoded.ok == false)
        #expect(decoded.error?.code == "project.noneOpen")
        #expect(decoded.result == nil)
    }

    /// This used to compare the catalog against a set of string literals written out below it, and
    /// the comment claimed "a new command that skips the catalog fails here". It could not: adding a
    /// case to `ControlCommand` and forgetting the catalog left the literals unchanged too, so the
    /// test compared the catalog against a copy of itself and passed. `CommandKind` is the join that
    /// makes the assertion real — `ControlCommand.kind` switches over it exhaustively, so a new case
    /// cannot compile until it is named there, and `allCases` then has nowhere to hide.
    @Test("The catalog describes every command exactly once, with no invented names")
    func catalogCoversTheSurface() {
        let names = CommandCatalog.descriptors.map(\.name)
        #expect(Set(names).count == names.count, "duplicate descriptors: \(names)")

        let described = CommandCatalog.describedKinds
        let missing = Set(CommandKind.allCases).subtracting(described)
        #expect(missing.isEmpty, "commands with no catalog entry: \(missing.map(\.rawValue).sorted())")

        // A descriptor whose name is not a real command is dropped by `describedKinds`, so the count
        // comparison is what catches a typo'd or stale entry.
        #expect(
            described.count == names.count,
            "descriptors naming no known command: \(names.filter { CommandKind(rawValue: $0) == nil })"
        )
    }

    /// Both hosts build this sentence, so it is a contract rather than a detail. It lived in each of
    /// them separately: the service answered `Reset 12 log entries and journey "Checkout"` and the
    /// window answered `Reset all.` — the same command, two answers, and a script driving both had no
    /// way to tell which it was talking to.
    @Test("A reset reports what it cleared, not what it was asked to clear")
    func resetMessageNamesWhatWasCleared() {
        // Nothing was in scope at all — a journey reset with no journey active.
        #expect(ControlMessages.reset(clearedLogEntries: nil, restartedJourneyName: nil) == "Nothing to reset.")
        // In scope but already empty. A count of zero is an answer: the log was cleared and held
        // nothing, which is a different fact from the log never having been looked at.
        #expect(ControlMessages.reset(clearedLogEntries: 0, restartedJourneyName: nil) == "Reset 0 log entries.")
        #expect(ControlMessages.reset(clearedLogEntries: 1, restartedJourneyName: nil) == "Reset 1 log entry.")
        #expect(ControlMessages.reset(clearedLogEntries: 12, restartedJourneyName: nil) == "Reset 12 log entries.")
        #expect(ControlMessages.reset(clearedLogEntries: nil, restartedJourneyName: "Checkout")
                == "Reset journey \"Checkout\".")
        #expect(ControlMessages.reset(clearedLogEntries: 12, restartedJourneyName: "Checkout")
                == "Reset 12 log entries and journey \"Checkout\".")
    }

    @Test("Every command reports the kind it is")
    func kindMatchesTheCase() {
        #expect(ControlCommand.ping.kind == .ping)
        #expect(ControlCommand.endpointList.kind == .endpointList)
        #expect(ControlCommand.journeyStepMove(journey: .name("j"), step: .index(0), toIndex: 1).kind == .journeyStepMove)
        #expect(ControlCommand.reset(scope: .all).kind == .reset)
        // Every kind is reachable, so `allCases` is a faithful index of the surface rather than a
        // list that has grown entries the enum no longer has.
        #expect(CommandKind.allCases.count == 47)
    }

    @Test("Every catalog entry names a CLI invocation")
    func catalogEntriesAreActionable() {
        for descriptor in CommandCatalog.descriptors {
            #expect(descriptor.cli.hasPrefix("mimic "), "\(descriptor.name) has no CLI spelling")
            #expect(descriptor.summary.isEmpty == false)
        }
    }
}

@Suite("Project document compatibility")
struct ProjectDocumentTests {

    @Test("A project exported before journeys existed still loads")
    func v1DocumentDecodes() throws {
        let v1 = """
        {
          "id": "6B1D3A2E-0000-4000-8000-000000000001",
          "schemaVersion": 1,
          "name": "Legacy",
          "serverConfiguration": { "port": 8080, "globalDelayMs": 0 },
          "endpoints": [],
          "createdAt": 0,
          "modifiedAt": 0
        }
        """
        let project = try JSONDecoder().decode(MockProject.self, from: Data(v1.utf8))
        #expect(project.name == "Legacy")
        #expect(project.journeys.isEmpty)
        #expect(project.activeJourneyID == nil)
    }

    @Test("A project with journeys round-trips, active selection included")
    func currentDocumentRoundTrips() throws {
        var project = MockProject(name: "Checkout")
        var executed = project
        _ = try ProjectCommandExecutor.apply(
            .journeyAddTemplate(templateID: "retry-after-failure", name: nil),
            to: &executed
        )
        project = executed
        project.activeJourneyID = project.journeys[0].id

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(MockProject.self, from: data)

        #expect(decoded == project)
        #expect(decoded.activeJourney?.steps.count == 4)
    }

    @Test("Summaries collapse a project into the shape a listing needs")
    func summariesReportCounts() throws {
        var project = MockProject(name: "Checkout", serverConfiguration: ServerConfiguration(port: 9000, globalDelayMs: 25))
        _ = try ProjectCommandExecutor.apply(.endpointCreate(name: nil, method: .get, path: "/a", spec: nil), to: &project)
        _ = try ProjectCommandExecutor.apply(.journeyCreate(name: "J", spec: nil), to: &project)

        let summary = ProjectSummary(project)
        #expect(summary.name == "Checkout")
        #expect(summary.port == 9000)
        #expect(summary.globalDelayMs == 25)
        #expect(summary.endpointCount == 1)
        #expect(summary.journeyCount == 1)
    }
}
