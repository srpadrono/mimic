import Foundation
import SwiftUI
import Testing
import Domain
@testable import AppFeatures

/// What the window's two selectable rows say, and what they carry, for somebody who is being read
/// them rather than looking at them.
///
/// Both facts are asserted for both rows because they answer different questions. The trait is what
/// an assistive technology *queries* — and what an XCUITest can assert — while the label is what is
/// spoken. A row that draws its selection as an accent stripe and states it nowhere else has told a
/// sighted user and nobody else, and in the request log that state is not decoration: it is the set
/// a capture-to-journey acts on.
@Suite("Selectable row accessibility")
@MainActor
struct SelectableRowAccessibilityTests {

    // MARK: - Fixtures

    /// Spelled out as typed constants rather than inline literals: `AccessibilityTraits` is an
    /// option set whose members are implicit, and naming the two states once keeps every assertion
    /// below comparing against the same pair.
    static let selectedRowTraits: AccessibilityTraits = [.isButton, .isSelected]
    static let unselectedRowTraits: AccessibilityTraits = .isButton

    /// A fixed instant, so nothing here depends on when the suite runs.
    static func log(
        method: HTTPMethod = .get,
        path: String = "/api/users",
        status: Int? = 200,
        failureLabel: String? = nil,
        outcome: RequestOutcome = .endpoint
    ) -> RequestLog {
        RequestLog(
            timestamp: Date(timeIntervalSince1970: 1_710_000_000),
            method: method,
            path: path,
            responseStatusCode: status,
            failureLabel: failureLabel,
            outcome: outcome
        )
    }

    private func row(log: RequestLog, isSelected: Bool, endpointName: String?, scenarioName: String?) -> RequestLogTableRow {
        RequestLogTableRow(
            log: log,
            rowIndex: 0,
            isSelected: isSelected,
            endpointName: endpointName,
            scenarioName: scenarioName,
            onSelect: { _ in }
        )
    }

    // MARK: - The request and its answer

    /// The opening clause follows `EndpointTrafficRow.spokenLabel` exactly, so the same request is
    /// announced the same way in the drawer and in the inspector's traffic list. Three arms, and the
    /// ordering between them matters: a failed request carries a `failureLabel` and no status code,
    /// so the failure arm must only be reachable when there is genuinely no code to speak.
    @Test("A row opens with the request and what came back")
    func speaksTheRequestAndItsAnswer() {
        #expect(
            RequestLogTableRow.spokenLabel(
                for: Self.log(),
                endpointName: nil,
                scenarioName: nil,
                isSelected: false
            ) == "GET /api/users, status 200"
        )

        #expect(
            RequestLogTableRow.spokenLabel(
                for: Self.log(method: .post, path: "/api/orders", status: nil, failureLabel: "timeout 30000ms"),
                endpointName: nil,
                scenarioName: nil,
                isSelected: false
            ) == "POST /api/orders, failed: timeout 30000ms"
        )

        #expect(
            RequestLogTableRow.spokenLabel(
                for: Self.log(path: "/api/void", status: nil),
                endpointName: nil,
                scenarioName: nil,
                isSelected: false
            ) == "GET /api/void, no response"
        )
    }

    /// The endpoint and scenario columns are two of the six the table draws, and they were the two
    /// the spoken row left out.
    @Test("A row names the endpoint and the scenario that answered")
    func speaksWhatAnswered() {
        #expect(
            RequestLogTableRow.spokenLabel(
                for: Self.log(),
                endpointName: "Users",
                scenarioName: "OK",
                isSelected: false
            ) == "GET /api/users, status 200, endpoint Users, scenario OK"
        )
    }

    /// With no endpoint name the cell draws the outcome instead, and the distinction it draws is the
    /// one this panel exists for: *nothing is configured for this call* against *a journey answered
    /// it*. Read as silence, those two rows are the same row.
    @Test("With no endpoint named, the row speaks the outcome the cell draws")
    func speaksTheOutcomeWhenNoEndpointIsNamed() {
        #expect(
            RequestLogTableRow.spokenLabel(
                for: Self.log(path: "/not-mocked", status: 404, outcome: .unmatched),
                endpointName: nil,
                scenarioName: nil,
                isSelected: false
            ) == "GET /not-mocked, status 404, unmatched"
        )

        #expect(
            RequestLogTableRow.spokenLabel(
                for: Self.log(path: "/off-script", status: 404, outcome: .blockedByJourney),
                endpointName: nil,
                scenarioName: nil,
                isSelected: false
            ) == "GET /off-script, status 404, blocked by journey"
        )

        #expect(
            RequestLogTableRow.spokenLabel(
                for: Self.log(path: "/checkout", outcome: .journey),
                endpointName: nil,
                scenarioName: nil,
                isSelected: false
            ) == "GET /checkout, status 200, answered by journey"
        )

        // An endpoint answered and has since been renamed or deleted. The cell draws an em dash,
        // and an em dash is not a thing to say.
        #expect(
            RequestLogTableRow.spokenLabel(
                for: Self.log(outcome: .endpoint),
                endpointName: nil,
                scenarioName: nil,
                isSelected: false
            ) == "GET /api/users, status 200"
        )
    }

    // MARK: - Selection

    @Test("Selection is spoken, and carried as a trait")
    func speaksAndCarriesSelection() {
        #expect(
            RequestLogTableRow.spokenLabel(
                for: Self.log(),
                endpointName: "Users",
                scenarioName: "OK",
                isSelected: true
            ) == "GET /api/users, status 200, endpoint Users, scenario OK, selected"
        )

        let log = Self.log()
        let selected = row(log: log, isSelected: true, endpointName: "Users", scenarioName: "OK")
        let unselected = row(log: log, isSelected: false, endpointName: "Users", scenarioName: "OK")

        #expect(selected.rowTraits == Self.selectedRowTraits)
        // Still a button: the row is a tap target, and the trait is what says so.
        #expect(unselected.rowTraits == Self.unselectedRowTraits)
    }

    // MARK: - The scenario row, one panel over

    /// The inspector's scenario row is the same shape of control — a tap target that is one of a set,
    /// with exactly one of them live — so it answers the same two ways. It drew its active state
    /// three times over (an accent bar, a filled mark, the word "Active") and carried it
    /// programmatically not at all.
    @Test("The active scenario carries the selected trait and says so")
    func activeScenarioRowIsSelected() {
        let scenario = Scenario(name: "Unauthorized", statusCode: 401)
        let active = ScenarioRow(
            scenario: scenario,
            isActive: true,
            isOnlyScenario: false,
            onTap: {},
            onDuplicate: {},
            onDelete: {}
        )
        let inactive = ScenarioRow(
            scenario: scenario,
            isActive: false,
            isOnlyScenario: false,
            onTap: {},
            onDuplicate: {},
            onDelete: {}
        )

        #expect(active.rowTraits == Self.selectedRowTraits)
        #expect(inactive.rowTraits == Self.unselectedRowTraits)

        #expect(ScenarioRow.spokenLabel(scenario: scenario, isActive: true) == "Unauthorized, status 401, active")
        #expect(ScenarioRow.spokenLabel(scenario: scenario, isActive: false) == "Unauthorized, status 401")
    }
}
