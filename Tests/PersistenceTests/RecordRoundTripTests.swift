import Testing
import Foundation
@testable import Persistence
import Domain

/// What the GRDB records are *made of*, checked against the domain types rather than against a list
/// somebody remembered to update.
///
/// Every record in `Sources/Persistence/Records` is a hand-written translation in both directions —
/// `init(from:)` names each field on the way down, `toDomain` names each one on the way back — and
/// until this file existed nothing compared either list against the type it claims to mirror.
/// Individual fields were asserted here and there — `JourneyPersistenceTests.responseDetailsRoundTrip`
/// walks most of a journey's by hand — but a hand-written assertion covers a field only if somebody
/// remembered to write one, which is the same gap one level down. The columns added most recently are
/// the demonstration: run `grep -rn graphqlOperation Tests/PersistenceTests` against everything but
/// this file and the only hits are `DocumentShapeTests`, which reads the *encoded document* and never
/// opens a database, and one sentence of prose in `MigrationTests`. Neither the `endpoint` nor the
/// `journeyStep` copy of that field had been shown to survive a save and a load. A dropped field is
/// not an error either: it is a value that comes back at its default with the suite still green.
///
/// The closure here is the same shape `DocumentShapeTests` uses for the stored document: **drive it
/// from the type.** Two tests, and neither one lists a field:
///
/// - `fixtureVariesEveryStoredProperty` walks each domain type with `Mirror` and requires the
///   fixture below to differ from a default-constructed value on *every* stored property. The
///   default-constructed value is exactly what a record that dropped the field would hand back, so
///   this is the assertion that makes a dropped field observable at all.
/// - `everyStoredPropertySurvivesTheRoundTrip` then saves the fixture and loads it, and compares the
///   whole project with `==`.
///
/// Together they close the hole in both directions. Add a property to `Endpoint` and forget the
/// fixture: the first test fails, naming the property. Add it to the fixture and forget
/// `EndpointRecord`: the second fails, because the value came back at the default the first test
/// just proved the fixture does not use.
///
/// The boundary is `domainTypes` in `fixtureVariesEveryStoredProperty`, and it is hand-written for
/// the same reason `DocumentShapeTests.documentTypes` is. A field on a type that list does not name
/// is still compared by the round trip — `==` reaches the whole tree — but nothing insists the
/// fixture varies it, so the guarantee lapses to "covered for as long as somebody happened to give it
/// a non-default value". Adding a type to what the records store means adding it there in the same
/// edit; that is the one thing this file cannot check for you.
@Suite("Record round trip")
struct RecordRoundTripTests {

    // MARK: - Fixture
    //
    // Every value below is chosen to differ from what the corresponding domain initialiser defaults
    // to — that is the property `fixtureVariesEveryStoredProperty` enforces, and the reason a dropped
    // column cannot round-trip cleanly. Nothing here is arbitrary-looking for its own sake.

    /// Whole seconds since the epoch, deliberately.
    ///
    /// GRDB stores a `Date` at millisecond resolution, so a fixture built from `Date()` would come
    /// back a fraction of a millisecond away and fail an equality check for reasons that have nothing
    /// to do with a dropped column. A whole second is exact under every encoding a store could pick.
    static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    /// A hundred seconds after `createdAt`, so a record that writes one timestamp into both columns
    /// is caught rather than hidden by a fixture whose two dates happen to be the same.
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

    /// Two scenarios with the **second** one active, so a record that dropped `activeScenarioID` and
    /// fell back to the first would be caught. With one scenario those two are the same scenario, and
    /// the difference is invisible — the same fixture trap `duplicateEndpointIsIndependent` in
    /// `DomainTests` was written out of.
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

    /// The hold is deliberately **not** `NetworkFailure.defaultTimeoutHoldMs`: that is the value
    /// `JourneyStepRecord.decodedOutcome` substitutes when `failureHoldMs` is missing, so a fixture
    /// using the default would round-trip perfectly with the column dropped.
    /// `timeoutHoldIsNotTheFallback` pins that, because an enum payload is not a stored property and
    /// the `Mirror` walk below cannot see it.
    static let timingOutStep = JourneyStep(
        name: "Summary hangs",
        method: .get,
        path: "/account-summary",
        outcome: .networkFailure(.timeout(holdMs: 7_500)),
        delayMs: 5,
        repeatCount: 2,
        graphqlOperation: "AccountSummaryPoll"
    )

    /// The other discriminator value for `failureKind`, and the one that leaves `failureHoldMs` null.
    static let droppingStep = JourneyStep(
        name: "Summary drops",
        method: .head,
        path: "/account-summary",
        outcome: .networkFailure(.connectionDrop),
        delayMs: 1,
        repeatCount: 3,
        graphqlOperation: "AccountSummaryDrop"
    )

    static let journey = Journey(
        name: "Retry after failure",
        summary: "The first call fails, the retry succeeds",
        steps: [respondingStep, timingOutStep, droppingStep],
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

    // MARK: - The round trip

    @Test("Every stored property survives init(from:) → insert → fetch → toDomain")
    func everyStoredPropertySurvivesTheRoundTrip() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)

        let original = Self.project
        try await repository.save(original)
        let loaded = try await repository.load(id: original.id)

        // The two timestamps are rounded to the second on the way out, and only those two.
        //
        // Nothing in this repository pins the resolution a `Date` keeps on its way through GRDB, and
        // a comparison that failed on a fraction of a millisecond would say nothing about a dropped
        // column while looking exactly like one. Both fixture timestamps sit on a whole second, so
        // this is a no-op for any store that is exact; and they are a hundred seconds apart, so it
        // cannot hide a timestamp column that was dropped, defaulted to "now", or written into the
        // other one. Every other property is compared as it came back.
        var normalized = loaded
        normalized.createdAt = Self.roundedToSecond(loaded.createdAt)
        normalized.modifiedAt = Self.roundedToSecond(loaded.modifiedAt)

        let savedJSON = try Self.readableJSON(original)
        let loadedJSON = try Self.readableJSON(loaded)
        #expect(
            normalized == original,
            """
            The project that came back out of the store is not the one that went in. A field that \
            differs here is a field one of the records in Sources/Persistence/Records does not \
            carry — check both directions, `init(from:)` and `toDomain`, and remember that a \
            dropped field shows up as its default rather than as an error.
            saved:
            \(savedJSON)
            loaded:
            \(loadedJSON)
            """
        )
    }

    /// `NetworkFailure.timeout(holdMs:)` keeps its payload in an enum case, which is not a stored
    /// property and so is invisible to the `Mirror` walk below. It is stored in its own column
    /// (`failureHoldMs`), and a missing one decodes to `NetworkFailure.defaultTimeoutHoldMs` rather
    /// than failing — so the fixture has to hold anything but that number for the column to be
    /// covered at all.
    @Test("The timeout fixture does not use the value a missing column decodes to")
    func timeoutHoldIsNotTheFallback() throws {
        guard case let .networkFailure(.timeout(holdMs)) = Self.timingOutStep.outcome else {
            Issue.record("timingOutStep is the fixture that carries a timeout")
            return
        }
        #expect(
            holdMs != NetworkFailure.defaultTimeoutHoldMs,
            """
            timingOutStep holds \(holdMs)ms, which is exactly what JourneyStepRecord substitutes for \
            a missing failureHoldMs — so the round trip above would pass with that column dropped. \
            Pick any other hold.
            """
        )
    }

    // MARK: - What makes the round trip able to fail

    @Test("The fixture varies every stored property, so a dropped column cannot pass unnoticed")
    func fixtureVariesEveryStoredProperty() throws {
        let domainTypes: [(fixture: Any, baseline: Any, name: String, exempt: Set<String>)] = [
            // `schemaVersion` is the one property no fixture can vary: `MockProject.init` stamps
            // `currentSchemaVersion` and the field is a `let`, so the fixture and the baseline are
            // always the same number. `ProjectRecord.toDomain`'s own documentation says the column
            // round-trips a constant, and `MigrationTests` covers the reading it does have —
            // `toDomainReportsTheCurrentVersionWhateverTheColumnHolds` and
            // `aNewerSchemaVersionIsRefusedOnLoad`.
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

        for entry in domainTypes {
            Self.expectEveryPropertyVaries(
                entry.fixture,
                from: entry.baseline,
                entry.name,
                exempt: entry.exempt
            )
        }
    }

    // MARK: - Helpers

    /// Fails for every stored property of `fixture` that still holds the value a default-constructed
    /// value of the same type holds.
    ///
    /// Reflection rather than a written-out list, because a written-out list is the thing this file
    /// exists to replace: a property added to the type shows up here on the next run without anybody
    /// editing a list, and an exemption naming a property that no longer exists is reported too.
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
                default-constructed \(typeName) holds — and therefore what a record that dropped the \
                column would hand back. Give it a distinct value in the fixture, or the round-trip \
                test cannot see that field at all.
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

    /// See the note at the call site: this exists so the comparison is about columns rather than
    /// about a store's timestamp resolution.
    static func roundedToSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
    }

    /// The whole project as sorted-key JSON, for the failure message only — a diff a human can read
    /// without a debugger, and complete by construction because it comes from `Codable`.
    static func readableJSON(_ project: MockProject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(project), as: UTF8.self)
    }
}
