import Foundation
import Testing
@testable import Domain

/// The five duplication helpers in `ProjectDuplication.swift`, checked against the types they copy
/// rather than against the field lists their own documentation asks a reader to keep in step.
///
/// Each helper enumerates its model's stored properties by hand, because the structurally complete
/// form — `var copy = self; copy.id = UUID()` — is unavailable while `id` is a `let`. That leaves
/// every carried field droppable: add a property to `Endpoint`, forget this file's counterpart in
/// `copyingWithFreshIdentifiers()`, and duplication silently produces a copy that is quietly not
/// one. It is not a hypothetical class here — `mimic endpoint duplicate` and `mimic project
/// duplicate` shipped disagreeing about which scenario a copy activates, and duplicating a project
/// with any content in it wrote nothing at all.
///
/// Two tests close it, and neither names a field:
///
/// - `fixturesVaryEveryStoredProperty` walks each type with `Mirror` and requires the fixture to
///   differ from a default-constructed value on every stored property. A dropped field surfaces as
///   that default, so this is what makes one observable.
/// - `copiesPreserveEveryFieldTheyDoNotFreshen` encodes source and copy through `Codable` — which is
///   synthesized from the stored properties, so it cannot be partial — and compares the two after
///   rewriting identifiers by **order of first appearance**. That last part is why the comparison
///   says more than "the same fields are present": `<id:0>` standing for both an endpoint's
///   `activeScenarioID` and its second scenario's `id` records that the two are the same identifier,
///   so a copy that repointed at the wrong scenario, or carried a reference into the original's
///   tree, reads as a different document.
///
/// Identity itself is the third test: a helper that returned `self` would satisfy both of the above.
///
/// The one boundary that stays hand-written is the type list in `fixturesVaryEveryStoredProperty`. A
/// field on a type it does not name is still compared by the encoded comparison, but nothing insists
/// the fixture varies it, so the guarantee lapses to "covered for as long as somebody happened to
/// give it a non-default value".
@Suite("Duplication completeness")
struct DuplicationCompletenessTests {

    // MARK: - Fixture
    //
    // Every value differs from what the corresponding initialiser defaults to, which is what
    // `fixturesVaryEveryStoredProperty` enforces and what makes a dropped field visible.

    static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let modifiedAt = Date(timeIntervalSince1970: 1_700_000_100)

    static let firstScenario = Scenario(
        name: "OK",
        statusCode: 200,
        headers: ["X-Mimic-Scenario": "ok"],
        body: #"{"ok":true}"#,
        bodyContentType: .json
    )

    static let activeScenario = Scenario(
        name: "Server error",
        statusCode: 503,
        headers: ["Retry-After": "120"],
        body: #"{"error":"maintenance"}"#,
        bodyContentType: .plainText
    )

    /// The **second** scenario is the active one, deliberately. With one scenario, following the
    /// source's active scenario and defaulting to the first are the same behaviour, which is exactly
    /// how the executor and this helper managed to disagree unnoticed.
    static let endpoint = Endpoint(
        name: "Account summary",
        method: .patch,
        path: "/account-summary",
        scenarios: [firstScenario, activeScenario],
        activeScenarioID: activeScenario.id,
        delayMs: 125,
        groupTag: "Billing",
        graphqlOperation: "AccountSummary"
    )

    static let response = JourneyResponse(
        statusCode: 418,
        headers: ["X-Mimic-Step": "1"],
        body: #"{"teapot":true}"#,
        contentType: .plainText
    )

    static let respondingStep = JourneyStep(
        name: "Summary answers",
        method: .put,
        path: "/account-summary",
        outcome: .respond(response),
        delayMs: 45,
        repeatCount: 4,
        graphqlOperation: "AccountSummary"
    )

    static let timingOutStep = JourneyStep(
        name: "Summary hangs",
        method: .get,
        path: "/account-summary",
        outcome: .networkFailure(.timeout(holdMs: 7_500)),
        delayMs: 5,
        repeatCount: 2,
        graphqlOperation: "AccountSummaryPoll"
    )

    static let journey = Journey(
        name: "Retry after failure",
        summary: "The first call fails, the retry succeeds",
        steps: [respondingStep, timingOutStep],
        matchMode: .strictSequence,
        completion: .restart,
        unmatchedBehavior: .notFound,
        autoAdvance: false
    )

    static let project = MockProject(
        name: "Round trip",
        serverConfiguration: ServerConfiguration(port: 9191, globalDelayMs: 250),
        endpoints: [endpoint],
        journeys: [journey],
        activeJourneyID: journey.id,
        createdAt: createdAt,
        modifiedAt: modifiedAt
    )

    // MARK: - What a copy keeps

    @Test("A copy carries every field except the identity it is supposed to remint")
    func copiesPreserveEveryFieldTheyDoNotFreshen() throws {
        try Self.expectStructurallyIdentical(
            Self.activeScenario.copyingWithFreshIdentifiers(),
            to: Self.activeScenario,
            "Scenario"
        )
        try Self.expectStructurallyIdentical(
            Self.respondingStep.copyingWithFreshIdentifiers(),
            to: Self.respondingStep,
            "JourneyStep"
        )
        // The other shape a step's outcome can take. `.respond` and `.networkFailure` encode to
        // different documents, so a helper could carry one and not the other.
        try Self.expectStructurallyIdentical(
            Self.timingOutStep.copyingWithFreshIdentifiers(),
            to: Self.timingOutStep,
            "JourneyStep (network failure)"
        )
        try Self.expectStructurallyIdentical(
            Self.endpoint.copyingWithFreshIdentifiers(),
            to: Self.endpoint,
            "Endpoint"
        )
        try Self.expectStructurallyIdentical(
            Self.journey.copyingWithFreshIdentifiers(),
            to: Self.journey,
            "Journey"
        )
    }

    /// `duplicated(name:)` is the one helper with fields it is *meant* to change beyond identity, and
    /// its own documentation names them: `name` is the parameter, and `createdAt`/`modifiedAt` take
    /// the initialiser's defaults because the copy was made now. Those three are asserted directly
    /// and then carried across before the structural comparison, so the comparison is about the
    /// fields nobody said would move.
    @Test("A duplicated project changes its name and its timestamps, and nothing else but identity")
    func duplicatedProjectChangesOnlyWhatItSaysItChanges() throws {
        let source = Self.project
        let copy = source.duplicated(name: "Round trip (Copy)")

        #expect(copy.name == "Round trip (Copy)")
        #expect(copy.createdAt != source.createdAt, "the copy was made now, not when the source was")
        #expect(copy.modifiedAt != source.modifiedAt)

        var expected = source
        expected.name = copy.name
        expected.createdAt = copy.createdAt
        expected.modifiedAt = copy.modifiedAt

        try Self.expectStructurallyIdentical(copy, to: expected, "MockProject")
    }

    /// A helper that simply returned `self` would satisfy every structural check above, which is why
    /// this is a separate assertion rather than a remark. The identifier sets come out of the encoded
    /// document, so a new identifier field joins them without an edit here.
    @Test("A copy shares no identifier with its source, at any level of the tree")
    func copiesShareNoIdentifierWithTheirSource() throws {
        try Self.expectFreshIdentifiers(
            Self.activeScenario.copyingWithFreshIdentifiers(),
            from: Self.activeScenario,
            "Scenario"
        )
        try Self.expectFreshIdentifiers(
            Self.respondingStep.copyingWithFreshIdentifiers(),
            from: Self.respondingStep,
            "JourneyStep"
        )
        try Self.expectFreshIdentifiers(
            Self.endpoint.copyingWithFreshIdentifiers(),
            from: Self.endpoint,
            "Endpoint"
        )
        try Self.expectFreshIdentifiers(
            Self.journey.copyingWithFreshIdentifiers(),
            from: Self.journey,
            "Journey"
        )
        try Self.expectFreshIdentifiers(
            Self.project.duplicated(name: "Round trip (Copy)"),
            from: Self.project,
            "MockProject"
        )
    }

    // MARK: - What makes those checks able to fail

    @Test("The fixture varies every stored property, so a dropped field cannot pass unnoticed")
    func fixturesVaryEveryStoredProperty() throws {
        let duplicatedTypes: [(fixture: Any, baseline: Any, name: String, exempt: Set<String>)] = [
            // `schemaVersion` is the one property no fixture can vary: `MockProject.init` stamps
            // `currentSchemaVersion` and the field is a `let`, so a default-constructed project and
            // this one always agree on it. `DocumentShapeTests` in PersistenceTests is what watches
            // that constant.
            (Self.project, MockProject(name: ""), "MockProject", ["schemaVersion"]),
            (Self.project.serverConfiguration, ServerConfiguration.default, "ServerConfiguration", []),
            (Self.endpoint, Endpoint(name: "", path: ""), "Endpoint", []),
            (Self.activeScenario, Scenario(name: ""), "Scenario", []),
            (Self.journey, Journey(name: ""), "Journey", []),
            (
                Self.respondingStep,
                JourneyStep(name: "", path: "", outcome: .respond(JourneyResponse())),
                "JourneyStep",
                []
            ),
            (Self.response, JourneyResponse(), "JourneyResponse", []),
        ]

        for entry in duplicatedTypes {
            Self.expectEveryPropertyVaries(
                entry.fixture,
                from: entry.baseline,
                entry.name,
                exempt: entry.exempt
            )
        }
    }

    // MARK: - Helpers

    static func expectStructurallyIdentical(
        _ copy: some Encodable,
        to source: some Encodable,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let sourceJSON = try Self.canonicalJSON(source)
        let copyJSON = try Self.canonicalJSON(copy)
        #expect(
            sourceJSON == copyJSON,
            """
            \(label)'s copy is not the same document as its source once identifiers are set aside. \
            A field that appears on one side and not the other, or at a different value, is a field \
            the duplication helper does not carry — or an identifier pointing somewhere it should \
            not.
            source: \(sourceJSON)
            copy:   \(copyJSON)
            """,
            sourceLocation: sourceLocation
        )
    }

    static func expectFreshIdentifiers(
        _ copy: some Encodable,
        from source: some Encodable,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let sourceIDs = try Self.identifiers(in: source)
        let copyIDs = try Self.identifiers(in: copy)
        #expect(
            !sourceIDs.isEmpty,
            "\(label) encodes no identifier, so there is nothing here for this test to be about",
            sourceLocation: sourceLocation
        )
        #expect(
            sourceIDs.isDisjoint(with: copyIDs),
            """
            \(label)'s copy reuses \(sourceIDs.intersection(copyIDs).sorted()). Shared identifiers \
            are not cosmetic: endpoint, scenario, journey and step ids are each a primary key across \
            the whole database rather than scoped to a project, so a copy carrying one collides with \
            its original on insert and the entire write rolls back — and an edit to the copy reaches \
            into the original's row.
            """,
            sourceLocation: sourceLocation
        )
    }

    /// The encoded value with keys sorted and every identifier replaced by its order of first
    /// appearance, so two documents that differ only in which UUIDs they use compare equal — and two
    /// that differ in *how the UUIDs refer to each other* do not.
    static func canonicalJSON(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return Self.withPositionalIdentifiers(in: String(decoding: data, as: UTF8.self))
    }

    /// Every identifier the value encodes, taken from the encoded document rather than from a list of
    /// properties — so an identifier added to a type later is covered without an edit here.
    static func identifiers(in value: some Encodable) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let text = String(decoding: data, as: UTF8.self)
        var found: Set<String> = []
        var searchStart = text.startIndex
        while let range = text.range(
            of: Self.uuidPattern,
            options: .regularExpression,
            range: searchStart..<text.endIndex
        ) {
            found.insert(String(text[range]))
            searchStart = range.upperBound
        }
        return found
    }

    static let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

    static func withPositionalIdentifiers(in text: String) -> String {
        var assigned: [String: String] = [:]
        var result = ""
        var searchStart = text.startIndex
        while let range = text.range(
            of: Self.uuidPattern,
            options: .regularExpression,
            range: searchStart..<text.endIndex
        ) {
            result.append(contentsOf: text[searchStart..<range.lowerBound])
            let identifier = String(text[range])
            let placeholder = assigned[identifier] ?? "<id:\(assigned.count)>"
            assigned[identifier] = placeholder
            result.append(placeholder)
            searchStart = range.upperBound
        }
        result.append(contentsOf: text[searchStart...])
        return result
    }

    /// Fails for every stored property of `fixture` that still holds the value a default-constructed
    /// value of the same type holds — which is exactly what a helper that dropped the field would
    /// produce.
    static func expectEveryPropertyVaries(
        _ fixture: Any,
        from baseline: Any,
        _ typeName: String,
        exempt: Set<String>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var baselineByLabel: [String: String] = [:]
        for child in Mirror(reflecting: baseline).children {
            guard let label = child.label else { continue }
            baselineByLabel[label] = String(describing: child.value)
        }

        var seen: Set<String> = []
        for child in Mirror(reflecting: fixture).children {
            guard let label = child.label else { continue }
            seen.insert(label)
            guard let defaultValue = baselineByLabel[label] else {
                Issue.record(
                    "\(typeName).\(label) has no counterpart on the default-constructed value",
                    sourceLocation: sourceLocation
                )
                continue
            }
            guard !exempt.contains(label) else { continue }
            #expect(
                String(describing: child.value) != defaultValue,
                """
                \(typeName).\(label) is left at \(defaultValue) in the fixture, which is what a \
                default-constructed \(typeName) holds — and therefore what a duplication helper that \
                dropped the field would hand back. Give it a distinct value here, or the copy checks \
                cannot see that field at all.
                """,
                sourceLocation: sourceLocation
            )
        }

        for label in exempt.subtracting(seen).sorted() {
            Issue.record(
                "\(typeName) has no stored property named \(label); the exemption is stale",
                sourceLocation: sourceLocation
            )
        }
    }
}
