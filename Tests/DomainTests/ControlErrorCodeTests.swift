import Foundation
import Testing
@testable import Domain

/// The codes a script branches on, asserted where they are produced.
///
/// `ControlError`'s own documentation calls these "stable, greppable" and says in as many words that
/// they exist "so scripts can match on them without parsing English" — which makes each one a
/// contract, and an unasserted contract is a rename away from silently breaking every caller that
/// reads it. `endpoint.notFound`, `project.notFound`, `project.noneOpen`, `journey.noneActive`,
/// `request.invalid` and the rest are pinned elsewhere in the suite; `scenario.notFound`,
/// `journey.notFound` and `journeyStep.notFound` were not pinned anywhere, in any target.
///
/// The other half of what these check is *which* failure comes back, which matters more than the
/// spelling. Every scenario command resolves an endpoint first and every step command resolves a
/// journey first, so the interesting case is not "a bad reference fails" — it is that a present
/// endpoint with an absent scenario reports the scenario, and a present journey with an absent step
/// reports the step. Reporting the parent instead sends a caller to fix the thing that is fine.
@Suite("Error codes a script branches on")
struct ControlErrorCodeTests {

    static let scenario = Scenario(name: "OK", statusCode: 200, body: "{}")

    static var endpoint: Endpoint {
        Endpoint(
            name: "Login",
            method: .post,
            path: "/login",
            scenarios: [scenario],
            activeScenarioID: scenario.id
        )
    }

    static var journey: Journey {
        Journey(
            name: "Retry",
            summary: "The first call fails, the retry succeeds",
            steps: [
                JourneyStep(
                    name: "fails",
                    method: .post,
                    path: "/login",
                    outcome: .respond(JourneyResponse(statusCode: 500))
                ),
                JourneyStep(
                    name: "succeeds",
                    method: .post,
                    path: "/login",
                    outcome: .respond(JourneyResponse(statusCode: 200))
                ),
            ],
            matchMode: .strictSequence,
            completion: .restart,
            unmatchedBehavior: .notFound,
            autoAdvance: false
        )
    }

    /// A project where the *parents* all exist: the endpoint, the journey and its two steps are real,
    /// so every failure below is genuinely about the leaf the command could not find.
    static var project: MockProject {
        MockProject(name: "Checkout", endpoints: [endpoint], journeys: [journey])
    }

    // MARK: - scenario.notFound

    @Test("A missing scenario on an endpoint that exists reports the scenario, not the endpoint")
    func scenarioNotFoundNamesTheScenario() throws {
        let commands: [ControlCommand] = [
            .scenarioUpdate(
                endpoint: .route(.post, "/login"),
                scenario: .name("nope"),
                spec: ScenarioSpec(statusCode: 500)
            ),
            .scenarioDelete(endpoint: .route(.post, "/login"), scenario: .name("nope")),
            .scenarioActivate(endpoint: .route(.post, "/login"), scenario: .name("nope")),
        ]

        for command in commands {
            guard let error = Self.failure(command, on: Self.project) else { continue }
            #expect(error.code == "scenario.notFound", "\(command.kind.rawValue) reported \(error.code)")
            #expect(error.details?["name"] == "nope")
        }
    }

    @Test("A scenario referenced by id reports that id back in the details")
    func scenarioNotFoundCarriesTheIdentifier() throws {
        let missing = UUID()
        guard let error = Self.failure(
            .scenarioDelete(endpoint: .route(.post, "/login"), scenario: .id(missing)),
            on: Self.project
        ) else { return }

        #expect(error.code == "scenario.notFound")
        #expect(error.details?["id"] == missing.uuidString)
    }

    // MARK: - journey.notFound

    @Test("Every command that starts from a journey reports journey.notFound when it is absent")
    func journeyNotFoundNamesTheJourney() throws {
        let absent = JourneyRef.name("nope")
        let commands: [ControlCommand] = [
            .journeyGet(journey: absent),
            .journeyUpdate(journey: absent, spec: JourneySpec(autoAdvance: true)),
            .journeyDelete(journey: absent),
            .journeyDuplicate(journey: absent),
            .journeyStepAdd(journey: absent, step: JourneyStepSpec(path: "/login"), atIndex: nil),
            .journeyStepsAdd(journey: absent, steps: [JourneyStepSpec(path: "/login")], atIndex: nil),
            .journeyStepUpdate(journey: absent, step: .index(0), spec: JourneyStepSpec(statusCode: 200)),
            .journeyStepRemove(journey: absent, step: .index(0)),
            .journeyStepMove(journey: absent, step: .index(0), toIndex: 1),
        ]

        for command in commands {
            guard let error = Self.failure(command, on: Self.project) else { continue }
            #expect(
                error.code == "journey.notFound",
                """
                \(command.kind.rawValue) reported \(error.code). A step command resolves its journey \
                first, so a missing journey has to say so — reporting the step would point the \
                caller at the wrong reference.
                """
            )
            #expect(error.details?["name"] == "nope")
        }
    }

    // MARK: - journeyStep.notFound

    @Test("A missing step in a journey that exists reports the step, by whichever handle was used")
    func journeyStepNotFoundNamesTheStep() throws {
        let present = JourneyRef.name("Retry")

        if let byIndex = Self.failure(
            .journeyStepUpdate(journey: present, step: .index(9), spec: JourneyStepSpec(statusCode: 200)),
            on: Self.project
        ) {
            #expect(byIndex.code == "journeyStep.notFound")
            #expect(byIndex.details?["index"] == "9")
            #expect(byIndex.message.contains("step index 9"))
        }

        if let byName = Self.failure(
            .journeyStepRemove(journey: present, step: .name("nope")),
            on: Self.project
        ) {
            #expect(byName.code == "journeyStep.notFound")
            #expect(byName.details?["name"] == "nope")
        }

        let missing = UUID()
        if let byIdentifier = Self.failure(
            .journeyStepMove(journey: present, step: .id(missing), toIndex: 0),
            on: Self.project
        ) {
            #expect(byIdentifier.code == "journeyStep.notFound")
            #expect(byIdentifier.details?["id"] == missing.uuidString)
        }
    }

    // MARK: - Duplicating a journey

    /// `ProjectCommandExecutor.duplicate(_ source: Journey)` had no test of its own. Its endpoint
    /// twin did — and that twin is why: the executor used to build its own endpoint copy, which
    /// disagreed with the shared helper about which scenario the copy activates. The journey arm has
    /// the same shape (helper owns identity, this owns the name), and nothing exercised it.
    ///
    /// What the copy *contains* is pinned by `DuplicationCompletenessTests` against the type. What is
    /// pinned here is the executor's half: the rename, where the copy lands, and that the original is
    /// left alone.
    @Test("Duplicating a journey appends a renamed copy and leaves the original untouched")
    func duplicatingAJourneyAppendsARenamedCopy() throws {
        let before = Self.project
        let source = try #require(before.journeys.first)

        var project = before
        let applied = try ProjectCommandExecutor.apply(
            .journeyDuplicate(journey: .name("Retry")),
            to: &project
        )
        let outcome = try #require(applied, "journeyDuplicate is project-scoped")

        #expect(outcome.didMutate)
        #expect(project.journeys.count == 2)

        let copy = try #require(project.journeys.last)
        #expect(copy.name == "Retry (Copy)")
        #expect(outcome.result.journey == copy, "the reply carries the copy, not the original")
        #expect(outcome.result.message == "Duplicated journey as \"Retry (Copy)\".")

        // Identity is new at both levels; sharing a step id lets an edit to the copy rewrite the
        // original's step, and sharing the journey id collides on insert.
        #expect(copy.id != source.id)
        #expect(Set(copy.steps.map(\.id)).isDisjoint(with: Set(source.steps.map(\.id))))

        // The script itself is the same script, in the same order.
        #expect(copy.steps.map(\.name) == source.steps.map(\.name))
        #expect(copy.steps.map(\.outcome) == source.steps.map(\.outcome))

        // And the original is exactly as it was — including its name, which is the field the copy
        // changes.
        #expect(project.journeys[0] == source)
        #expect(project.activeJourneyID == before.activeJourneyID, "duplicating does not activate")
    }

    // MARK: - Helpers

    /// Applies `command` and returns the `ControlError` it threw, recording an issue if it did not
    /// throw one. Returns `nil` in that case so a loop can carry on and report every command rather
    /// than stopping at the first.
    static func failure(
        _ command: ControlCommand,
        on project: MockProject,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> ControlError? {
        var copy = project
        do {
            _ = try ProjectCommandExecutor.apply(command, to: &copy)
            Issue.record(
                "\(command.kind.rawValue) was expected to fail and did not",
                sourceLocation: sourceLocation
            )
            return nil
        } catch let error as ControlError {
            return error
        } catch {
            Issue.record(
                "\(command.kind.rawValue) threw \(error), which is not a ControlError",
                sourceLocation: sourceLocation
            )
            return nil
        }
    }
}
