import Testing
import Foundation
@testable import Domain

@Suite("EndpointValidation")
struct EndpointValidationTests {

    // MARK: - Path Validation

    @Test func validPathStartingWithSlash() throws {
        try EndpointValidator.validatePath("/")
    }

    @Test func validPathWithSegments() throws {
        try EndpointValidator.validatePath("/users/123")
    }

    @Test func invalidPathMissingLeadingSlash() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validatePath("users/123")
        }
    }

    @Test func invalidPathWithDoubleSlashes() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validatePath("//users")
        }
    }

    @Test func invalidPathWithLeadingWhitespace() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validatePath(" /users")
        }
    }

    @Test func invalidPathWithTrailingWhitespace() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validatePath("/users ")
        }
    }

    // MARK: - Status Code Validation

    @Test func validStatusCode200() throws {
        try EndpointValidator.validateStatusCode(200)
    }

    /// This was a verbatim copy of the line above it — `validateStatusCode(200)` twice, under two
    /// names, so the pair asserted one fact and reported two passes. The boundary it claims to check
    /// is the range `EndpointValidator.serveableStatusCodes` publishes, so it is read from there:
    /// a hand-written `200` cannot notice the floor moving, which is exactly what happened when 1xx
    /// was removed from the accepted range.
    @Test func validStatusCodeBoundaryLow() throws {
        try EndpointValidator.validateStatusCode(EndpointValidator.serveableStatusCodes.lowerBound)
        #expect(EndpointValidator.serveableStatusCodes.lowerBound == 200)
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validateStatusCode(EndpointValidator.serveableStatusCodes.lowerBound - 1)
        }
    }

    @Test func validStatusCodeBoundaryHigh() throws {
        try EndpointValidator.validateStatusCode(EndpointValidator.serveableStatusCodes.upperBound)
        #expect(EndpointValidator.serveableStatusCodes.upperBound == 599)
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validateStatusCode(EndpointValidator.serveableStatusCodes.upperBound + 1)
        }
    }

    @Test func invalidStatusCode600() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validateStatusCode(600)
        }
    }

    @Test func invalidStatusCode99() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validateStatusCode(99)
        }
    }

    /// 1xx used to be accepted, and serving one crashed the app.
    ///
    /// NIO's server pipeline treats an informational head as "an interim response, more to follow"
    /// and does not advance its state machine; the body that follows then fails an assertion. There
    /// is nothing lost by refusing them — a client never sees a 1xx as the answer to its request.
    @Test func informationalStatusCodesAreRejected() {
        for code in [100, 101, 102, 199] {
            #expect(throws: ValidationError.self) {
                try EndpointValidator.validateStatusCode(code)
            }
        }
    }

    @Test func negativeStatusCodeIsRejected() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validateStatusCode(-1)
        }
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validateStatusCode(Int.min)
        }
    }

    // MARK: - Port Validation

    @Test func validPort8080() throws {
        try EndpointValidator.validatePort(8080)
    }

    @Test func validPortBoundaryLow() throws {
        try EndpointValidator.validatePort(1)
    }

    @Test func validPortBoundaryHigh() throws {
        try EndpointValidator.validatePort(65535)
    }

    @Test func invalidPortZero() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validatePort(0)
        }
    }

    @Test func invalidPortNegative() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validatePort(-1)
        }
    }

    // MARK: - LocalizedError

    @Test func validationErrorProvidesLocalizedDescription() {
        let pathError = ValidationError.invalidPath("test")
        #expect(pathError.localizedDescription.contains("test"))

        let statusError = ValidationError.invalidStatusCode(999)
        #expect(statusError.localizedDescription.contains("999"))

        let portError = ValidationError.invalidPort(-5)
        #expect(portError.localizedDescription.contains("-5"))
    }
}

/// Whole-document validation, which is the only thing standing between an imported project and the
/// serving path.
///
/// Both hosts run `ProjectValidator.validate` before a document reaches the store, so a document it
/// accepts is one the app will try to serve. Each case below therefore asserts two things: that the
/// document is refused, and *what goes wrong when it is not* — because the failures this validator
/// was extended to catch are all silent at serving time, which is why they were worth catching at
/// all rather than left to be noticed.
@Suite("ProjectValidator")
struct ProjectValidatorTests {

    private static func endpoint(
        name: String = "Summary",
        path: String = "/account-summary",
        scenarios: [Scenario],
        activeScenarioID: UUID?
    ) -> Endpoint {
        Endpoint(
            name: name,
            method: .get,
            path: path,
            scenarios: scenarios,
            activeScenarioID: activeScenarioID
        )
    }

    /// Runs `validate` and hands back the `invalidDocument` it threw, failing the test for any other
    /// outcome. The context/reason split is the part a caller reads, so it is what gets returned.
    private static func refusal(
        _ project: MockProject,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (context: String, reason: String) {
        do {
            try ProjectValidator.validate(project)
        } catch ValidationError.invalidDocument(let context, let reason) {
            return (context, reason)
        } catch {
            Issue.record("expected an invalidDocument, got \(error)", sourceLocation: sourceLocation)
            throw error
        }
        Issue.record("expected the document to be refused", sourceLocation: sourceLocation)
        throw ValidationError.invalidDocument(context: "test", reason: "not refused")
    }

    @Test("A document the app itself could have written is accepted")
    func aWellFormedDocumentPasses() throws {
        let scenario = Scenario(name: "Default", statusCode: 200, body: "{}")
        var project = MockProject(
            name: "Checkout",
            endpoints: [Self.endpoint(scenarios: [scenario], activeScenarioID: scenario.id)],
            journeys: [Journey(name: "Flow", steps: [
                JourneyStep(name: "one", method: .get, path: "/a", outcome: .respond(JourneyResponse(statusCode: 200)))
            ])]
        )
        project.activeJourneyID = project.journeys[0].id

        try ProjectValidator.validate(project)
    }

    /// Every editing command maintains this reference as an invariant — `scenarioDelete` repoints
    /// `activeScenarioID` at the first surviving scenario — so a document carrying a dangling one did
    /// not come from this app, which is exactly what an import is.
    @Test("An activeScenarioID naming no scenario the endpoint owns is refused, with the endpoint named")
    func danglingActiveScenarioIDIsRefused() throws {
        let scenario = Scenario(name: "Default", statusCode: 200)
        let project = MockProject(
            name: "Checkout",
            endpoints: [Self.endpoint(scenarios: [scenario], activeScenarioID: UUID())]
        )

        let refusal = try Self.refusal(project)
        #expect(refusal.context.contains("Summary"))
        #expect(refusal.context.contains("GET /account-summary"))
        #expect(refusal.reason.contains("activeScenarioID"))
    }

    /// Why it matters, asserted rather than asserted-about: `RequestMatcher.match` skips an endpoint
    /// whose `activeScenarioID` resolves to no scenario it owns — two `continue`s before it can win —
    /// so the route answers 404 as though it had never been configured. Nothing in the window or the
    /// log says the endpoint exists and cannot answer.
    @Test("An endpoint with a dangling active scenario silently 404s, which is why validation catches it")
    func aDanglingActiveScenarioServesNothing() {
        let scenario = Scenario(name: "Default", statusCode: 200, body: "{}")
        let broken = Self.endpoint(scenarios: [scenario], activeScenarioID: UUID())

        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/account-summary"),
            endpoints: [broken],
            globalDelayMs: 0
        )
        #expect(plan.response.statusCode == 404)
        #expect(plan.response.matchedEndpointID == nil)
    }

    /// The other arm of the same field, and the one this validator used to accept: written as
    /// `if let activeScenarioID, !contains`, a *missing* id was the passing case. It is not the safe
    /// half — `RequestMatcher.match` declines the endpoint at the `guard let` one line above the
    /// lookup that catches a dangling one.
    @Test("An endpoint carrying scenarios and no activeScenarioID is refused, with the endpoint named")
    func aMissingActiveScenarioIDIsRefused() throws {
        let project = MockProject(
            name: "Checkout",
            endpoints: [
                Self.endpoint(scenarios: [Scenario(name: "Default", statusCode: 200)], activeScenarioID: nil)
            ]
        )

        let refusal = try Self.refusal(project)
        #expect(refusal.context.contains("Summary"))
        #expect(refusal.context.contains("GET /account-summary"))
        #expect(refusal.reason.contains("activeScenarioID"))
    }

    /// Why the two are one rule: the endpoint the app would have refused to build answers exactly what
    /// the dangling one answers, and a caller reading `mimic endpoint list` sees a configured route in
    /// both cases.
    @Test("An endpoint with scenarios and no active one silently 404s, exactly as a dangling id does")
    func anUnsetActiveScenarioServesNothing() {
        let scenario = Scenario(name: "Default", statusCode: 200, body: "{}")
        let unset = Self.endpoint(scenarios: [scenario], activeScenarioID: nil)

        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/account-summary"),
            endpoints: [unset],
            globalDelayMs: 0
        )
        #expect(plan.response.statusCode == 404)
        #expect(plan.response.matchedEndpointID == nil)
    }

    /// The case the rule above must not swallow, and the reason it asks about the scenarios rather
    /// than about the id alone: deleting an endpoint's last scenario leaves `scenarios` empty and
    /// `activeScenarioID` nil — `scenarioDelete` repoints at `scenarios.first?.id` — so this is a
    /// document the app itself exports, and refusing it would refuse a round trip.
    @Test("An endpoint with no scenarios at all is accepted with no active scenario")
    func anEndpointWithNoScenariosIsAccepted() throws {
        let project = MockProject(
            name: "Checkout",
            endpoints: [Self.endpoint(scenarios: [], activeScenarioID: nil)]
        )

        try ProjectValidator.validate(project)
    }

    @Test("An activeJourneyID naming no journey the project contains is refused, with the project named")
    func danglingActiveJourneyIDIsRefused() throws {
        var project = MockProject(name: "Checkout", journeys: [Journey(name: "Flow")])
        project.activeJourneyID = UUID()

        let refusal = try Self.refusal(project)
        #expect(refusal.context.contains("Checkout"))
        #expect(refusal.reason.contains("activeJourneyID"))
    }

    /// The other half of that one: `MockProject.activeJourney` reads a dangling id as `nil`, so the
    /// server runs with no overlay at all while the document says a journey is active. Deliberate
    /// behaviour for a *deleted* journey, and indistinguishable from a broken import — hence the check.
    @Test("A dangling activeJourneyID reads as no journey, so the server would run with no overlay")
    func aDanglingActiveJourneyIsInert() {
        var project = MockProject(name: "Checkout", journeys: [Journey(name: "Flow")])
        project.activeJourneyID = UUID()
        #expect(project.activeJourneyID != nil)
        #expect(project.activeJourney == nil)
    }

    /// A document from a build that understands a later schema cannot be read down safely: the fields
    /// this build does not know about are exactly the ones that would be dropped, and
    /// `MockProject.init(from:)` keeps the higher number while the synthesized encoder writes it back
    /// out — so it would be stored as a current project still claiming to be a future one.
    @Test("A document from a newer schema is refused, naming both versions")
    func aFutureSchemaVersionIsRefused() throws {
        let future = try Self.decodeProject(schemaVersion: MockProject.currentSchemaVersion + 1)
        #expect(future.schemaVersion == MockProject.currentSchemaVersion + 1, "the decoder keeps the document's version")

        let refusal = try Self.refusal(future)
        #expect(refusal.reason.contains("schemaVersion"))
        #expect(refusal.reason.contains(String(MockProject.currentSchemaVersion + 1)))
        #expect(refusal.reason.contains(String(MockProject.currentSchemaVersion)))
    }

    @Test("The current schema and every older one are accepted")
    func supportedSchemaVersionsPass() throws {
        for version in 1...MockProject.currentSchemaVersion {
            try ProjectValidator.validate(try Self.decodeProject(schemaVersion: version))
        }
    }

    /// A `schemaVersion` other than the current one can only be produced by decoding — the memberwise
    /// initializer hard-codes `MockProject.currentSchemaVersion`, which is the same reason the number
    /// cannot survive a persistence round trip through `ProjectRecord.toDomain`.
    private static func decodeProject(schemaVersion: Int) throws -> MockProject {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "schemaVersion": \(schemaVersion),
          "name": "From another build",
          "serverConfiguration": { "port": 8080, "globalDelayMs": 0 },
          "endpoints": [],
          "createdAt": 0,
          "modifiedAt": 0
        }
        """
        return try JSONDecoder().decode(MockProject.self, from: Data(json.utf8))
    }

    /// The per-field failures still name the endpoint the same way the reference failures do — the
    /// two build their context from one shared helper, and a reader looking for "which endpoint?"
    /// should not have to know which kind of failure they are reading.
    @Test("A field failure and a reference failure name the endpoint identically")
    func bothFailureKindsNameTheEndpointTheSameWay() throws {
        let bad = Scenario(name: "Default", statusCode: 999)
        let fieldFailure = try Self.refusal(
            MockProject(
                name: "Checkout",
                endpoints: [Self.endpoint(scenarios: [bad], activeScenarioID: bad.id)]
            )
        )

        let good = Scenario(name: "Default", statusCode: 200)
        let referenceFailure = try Self.refusal(
            MockProject(
                name: "Checkout",
                endpoints: [Self.endpoint(scenarios: [good], activeScenarioID: UUID())]
            )
        )

        #expect(fieldFailure.context == referenceFailure.context)
        #expect(fieldFailure.reason != referenceFailure.reason)
        // And the reason is stated once, not wrapped in a second `invalidDocument`.
        #expect(fieldFailure.reason.contains("Invalid status code"))
        #expect(fieldFailure.reason.contains("endpoint \"Summary\"") == false)
    }
}
