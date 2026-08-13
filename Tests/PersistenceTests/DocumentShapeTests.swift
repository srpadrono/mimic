import Testing
import Foundation
import Domain

/// What the stored document is *made of*, pinned to the version number that describes it.
///
/// It lives beside the persistence tests because this is where the number is spent:
/// `GRDBProjectRepository.load` calls `ProjectRecord.requireSupportedSchemaVersion`, which compares a
/// stored row against `MockProject.currentSchemaVersion` and refuses anything higher. That guard is
/// only ever as good as the constant, and the constant had already drifted once: `Endpoint` and
/// `JourneyStep` carried `graphqlOperation`, and the schema carried the `v3_graphql_operation`
/// migration that stores it, while `currentSchemaVersion` still read 2 — so a document carrying an
/// operation was stamped with a version that predates the field, and a build without it would open
/// that document as current and drop the field. `MigrationTests` could not catch that: every
/// assertion there that exercises the guard is written against `currentSchemaVersion` or
/// `currentSchemaVersion + 1`, so it holds for *any* value of the constant, a stale one included.
///
/// What that needs is a fact the constant cannot supply about itself, so this records one: the set of
/// key paths a fully-populated project encodes to. Add a field to any of the seven types listed in
/// `documentTypes` and the set changes, and the only way to make the suite green again is to look at
/// this file — which is where the version bump is asked for. It cannot *force* the bump (nothing can
/// force an integer to move), but it does make adding a field to those types silent-proof.
///
/// The boundary is `documentTypes`, and it is hand-written: a field on a type *not* on that list —
/// a nested type introduced later, say — is still invisible here. Adding a type to the document
/// means adding it there in the same edit, which is the one thing this file cannot check for you.
@Suite("Stored document shape")
struct DocumentShapeTests {

    /// The version `recordedKeyPaths` below describes. Bumped with `currentSchemaVersion`, never
    /// before or after it.
    private static let recordedShapeVersion = 3

    /// Every key path `fullyPopulatedProject()` encodes to, as of `recordedShapeVersion`.
    ///
    /// Array elements collapse — `endpoints[].id`, not one path per endpoint — because what is being
    /// recorded is the document's shape, and two endpoints have one shape between them. A container's
    /// own path is recorded as well as its children's, so a field whose type changes from a scalar to
    /// an object still shows up as new paths.
    ///
    /// `headers` is free-form: JSON cannot tell a dictionary from a struct, so the fixture's one
    /// header key appears here as though it were part of the schema. It is data — rename it in the
    /// fixture and rename it here too.
    private static let recordedKeyPaths: Set<String> = [
        // MockProject
        "id",
        "schemaVersion",
        "name",
        "serverConfiguration",
        "endpoints",
        "journeys",
        "activeJourneyID",
        "createdAt",
        "modifiedAt",

        // ServerConfiguration
        "serverConfiguration.port",
        "serverConfiguration.globalDelayMs",

        // Endpoint
        "endpoints[].id",
        "endpoints[].name",
        "endpoints[].method",
        "endpoints[].path",
        "endpoints[].scenarios",
        "endpoints[].activeScenarioID",
        "endpoints[].delayMs",
        "endpoints[].groupTag",
        "endpoints[].graphqlOperation",

        // Scenario
        "endpoints[].scenarios[].id",
        "endpoints[].scenarios[].name",
        "endpoints[].scenarios[].statusCode",
        "endpoints[].scenarios[].headers",
        "endpoints[].scenarios[].headers.Content-Type",
        "endpoints[].scenarios[].body",
        "endpoints[].scenarios[].bodyContentType",

        // Journey
        "journeys[].id",
        "journeys[].name",
        "journeys[].summary",
        "journeys[].steps",
        "journeys[].matchMode",
        "journeys[].completion",
        "journeys[].unmatchedBehavior",
        "journeys[].autoAdvance",

        // JourneyStep
        "journeys[].steps[].id",
        "journeys[].steps[].name",
        "journeys[].steps[].method",
        "journeys[].steps[].path",
        "journeys[].steps[].outcome",
        "journeys[].steps[].delayMs",
        "journeys[].steps[].repeatCount",
        "journeys[].steps[].graphqlOperation",

        // JourneyStepOutcome.respond — an unlabelled associated value, so its payload sits under
        // `_0`, the spelling `GraphQLDocumentCompatibilityTests.legacyStepDecodes` reads back.
        "journeys[].steps[].outcome.respond",
        "journeys[].steps[].outcome.respond._0",
        "journeys[].steps[].outcome.respond._0.statusCode",
        "journeys[].steps[].outcome.respond._0.headers",
        "journeys[].steps[].outcome.respond._0.headers.Content-Type",
        "journeys[].steps[].outcome.respond._0.body",
        "journeys[].steps[].outcome.respond._0.contentType",

        // JourneyStepOutcome.networkFailure — both `NetworkFailure` cases, because a case is part of
        // the document too: `{"connectionDrop":{}}` and `{"timeout":{"holdMs":…}}` are what
        // `ControlCommandTests.networkFailureShape` pins.
        "journeys[].steps[].outcome.networkFailure",
        "journeys[].steps[].outcome.networkFailure._0",
        "journeys[].steps[].outcome.networkFailure._0.connectionDrop",
        "journeys[].steps[].outcome.networkFailure._0.timeout",
        "journeys[].steps[].outcome.networkFailure._0.timeout.holdMs",
    ]

    @Test("A field added to the stored document moves the schema version with it")
    func documentShapeMatchesTheRecordedVersion() throws {
        #expect(
            Self.recordedShapeVersion == MockProject.currentSchemaVersion,
            """
            MockProject.currentSchemaVersion is \(MockProject.currentSchemaVersion), but the shape \
            recorded in DocumentShapeTests is for \(Self.recordedShapeVersion). Whatever moved the \
            version was a change to what this build writes: re-record the key paths below and set \
            recordedShapeVersion to match. If the version moved for a reason the encoding does not \
            show, the number alone is the edit.
            """
        )

        let encoded = try Self.encodedKeyPaths(of: Self.fullyPopulatedProject())
        let added = encoded.subtracting(Self.recordedKeyPaths).sorted()
        let removed = Self.recordedKeyPaths.subtracting(encoded).sorted()

        #expect(
            added.isEmpty && removed.isEmpty,
            """
            The document MockProject encodes no longer matches the shape recorded for schemaVersion \
            \(Self.recordedShapeVersion).
              added:   \(added)
              removed: \(removed)
            A field added to the stored document is a new schema. Bump \
            MockProject.currentSchemaVersion, set DocumentShapeTests.recordedShapeVersion to the same \
            number, and update recordedKeyPaths — in one commit. Leaving the constant behind is how \
            graphqlOperation came to ship inside documents still stamped version 2, where a build \
            that predates the field reads them as current and drops it.
            """
        )
    }

    /// The shape above can only see what the fixture populates: an optional left `nil` encodes to no
    /// key at all, so a new optional field would sail past the diff. This is what closes that —
    /// `Mirror` reports a stored property whether or not it is set, so every property of every type in
    /// the document must show up as an encoded key path.
    ///
    /// It also fires if a `CodingKeys` case renames a property on the way out, which is not a fixture
    /// problem. The message covers both, because from here the two look identical.
    @Test("Every stored property of the document reaches the encoded shape")
    func theFixtureLeavesNoFieldUnencoded() throws {
        let project = Self.fullyPopulatedProject()
        let endpoint = try #require(project.endpoints.first)
        let scenario = try #require(endpoint.scenarios.first)
        let journey = try #require(project.journeys.first)
        let step = try #require(journey.steps.first)
        guard case let .respond(response) = step.outcome else {
            Issue.record("the fixture's first step is the one that carries a JourneyResponse")
            return
        }

        let encoded = try Self.encodedKeyPaths(of: project)
        let documentTypes: [(value: Any, prefix: String)] = [
            (project, ""),
            (project.serverConfiguration, "serverConfiguration"),
            (endpoint, "endpoints[]"),
            (scenario, "endpoints[].scenarios[]"),
            (journey, "journeys[]"),
            (step, "journeys[].steps[]"),
            (response, "journeys[].steps[].outcome.respond._0"),
        ]

        for (value, prefix) in documentTypes {
            for child in Mirror(reflecting: value).children {
                guard let label = child.label else { continue }
                let path = prefix.isEmpty ? label : "\(prefix).\(label)"
                #expect(
                    encoded.contains(path),
                    """
                    \(path) is a stored property of the document but no such key was encoded. Either \
                    fullyPopulatedProject() leaves it nil — every optional has to be set, or the \
                    shape check cannot see the field — or a CodingKeys case renames it, in which \
                    case record the encoded spelling in recordedKeyPaths instead.
                    """
                )
            }
        }
    }

    // MARK: - Fixture

    /// A project with **every** optional set, at every level.
    ///
    /// Populated rather than default-constructed on purpose: nothing in Domain writes its own
    /// `encode(to:)`, and a synthesised encoder omits a `nil` optional rather than writing null —
    /// which is what `ControlCommandTests.resultsOmitUnusedFields` reads back as
    /// `{"ok":true,"result":{"message":"Done"}}`, no `error` key in sight. A field left nil here would
    /// contribute no key and be invisible to the shape above. Both `NetworkFailure` cases appear for
    /// the same reason: a case with no payload (`connectionDrop`) and one with a payload (`timeout`)
    /// encode to different shapes, and only the case the fixture uses is visible.
    private static func fullyPopulatedProject() -> MockProject {
        let scenarioID = UUID()
        let scenario = Scenario(
            id: scenarioID,
            name: "Success",
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"ok":true}"#,
            bodyContentType: .json
        )
        let endpoint = Endpoint(
            name: "Login",
            method: .post,
            path: "/login",
            scenarios: [scenario],
            activeScenarioID: scenarioID,
            delayMs: 25,
            groupTag: "auth",
            graphqlOperation: "Login"
        )
        let journey = Journey(
            name: "Retry after failure",
            summary: "The first call fails, the retry succeeds",
            steps: [
                JourneyStep(
                    name: "Login succeeds",
                    method: .post,
                    path: "/login",
                    outcome: .respond(
                        JourneyResponse(
                            statusCode: 200,
                            headers: ["Content-Type": "application/json"],
                            body: #"{"ok":true}"#,
                            contentType: .json
                        )
                    ),
                    delayMs: 10,
                    repeatCount: 2,
                    graphqlOperation: "Login"
                ),
                JourneyStep(
                    name: "Summary hangs",
                    method: .get,
                    path: "/account-summary",
                    outcome: .networkFailure(.timeout(holdMs: 5_000)),
                    delayMs: 0,
                    repeatCount: 1,
                    graphqlOperation: "AccountSummary"
                ),
                JourneyStep(
                    name: "Summary drops",
                    method: .get,
                    path: "/account-summary",
                    outcome: .networkFailure(.connectionDrop),
                    delayMs: 0,
                    repeatCount: 1,
                    graphqlOperation: "AccountSummary"
                ),
            ],
            matchMode: .orderedPerEndpoint,
            completion: .stop,
            unmatchedBehavior: .fallThroughToEndpoints,
            autoAdvance: true
        )
        return MockProject(
            name: "Shape",
            serverConfiguration: ServerConfiguration(port: 8080, globalDelayMs: 5),
            endpoints: [endpoint],
            journeys: [journey],
            activeJourneyID: journey.id
        )
    }

    // MARK: - Walking the encoded document

    private static func encodedKeyPaths(of project: MockProject) throws -> Set<String> {
        let data = try JSONEncoder().encode(project)
        let object = try JSONSerialization.jsonObject(with: data)
        return keyPaths(of: object, prefix: "")
    }

    /// Dotted paths for every key below `value`, with `[]` marking a step through an array.
    ///
    /// A container contributes its own path *and* its children's, so an empty object still records
    /// that it was there — `{"connectionDrop":{}}` is a case of the document, not an absence.
    private static func keyPaths(of value: Any, prefix: String) -> Set<String> {
        if let object = value as? [String: Any] {
            var paths: Set<String> = []
            for (key, child) in object {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                paths.insert(path)
                paths.formUnion(keyPaths(of: child, prefix: path))
            }
            return paths
        }
        if let array = value as? [Any] {
            var paths: Set<String> = []
            for element in array {
                paths.formUnion(keyPaths(of: element, prefix: prefix + "[]"))
            }
            return paths
        }
        return []
    }
}
