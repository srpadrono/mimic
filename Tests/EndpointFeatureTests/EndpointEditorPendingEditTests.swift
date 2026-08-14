import Testing
import Domain
@testable import AppFeatures

/// What becomes of an edit that is still settling when the endpoint underneath it changes.
///
/// The status code, the response headers and the body commit 300ms after the typing stops, and
/// `CenterPaneView` builds the editor with no `.id(…)` — so clicking a second endpoint hands the
/// *same* `@State` boxes a new set of values. Filling those boxes from the new endpoint trips every
/// `onChange` the editor has, and each handler opens by dropping the timer holding the value the
/// user was typing. Because a keystroke restarts the timer, what that lost was never the tail of the
/// typing: it was all of it.
///
/// These tests call the two handlers rather than the fields, because the fields are AppKit text
/// views and a unit test has no way to type into one: `debounce…()` is what `.onChange` runs on a
/// keystroke, and `endpointSelectionChanged()` is what `.onChange(of: endpoint.id)` runs on the
/// click. The one thing they stand in for is SwiftUI's identity — two view values sharing one
/// `EndpointEditorPendingEdits` is what a single view identity across the switch amounts to.
///
/// Every field the editor is holding is passed as a literal. Nothing here is derived from the
/// endpoint by the code under test, so a change to `syncedValues` cannot quietly move what a test
/// believes was on screen.
@Suite("Endpoint editor pending edits")
struct EndpointEditorPendingEditTests {

    /// What one endpoint was asked to write, so a test can say *which* endpoint received an edit
    /// rather than only that one did.
    private final class ScenarioWrites {
        var statusCodes: [Int] = []
        var headers: [[String: String]] = []
        var bodies: [String] = []
    }

    private func recording(into writes: ScenarioWrites) -> EndpointEditorActions {
        EndpointEditorActions(
            onDuplicate: {},
            onDelete: {},
            onUpdateScenario: { statusCode, headers, body in
                if let statusCode { writes.statusCodes.append(statusCode) }
                if let headers { writes.headers.append(headers) }
                if let body { writes.bodies.append(body) }
            },
            onUpdateDelay: { _ in },
            onUpdateGroupTag: { _ in }
        )
    }

    private func makeScenario(
        statusCode: Int,
        headers: [String: String],
        body: String?
    ) -> Scenario {
        Scenario(name: "Default", statusCode: statusCode, headers: headers, body: body)
    }

    private func makeEndpoint(path: String, scenario: Scenario) -> Endpoint {
        Endpoint(
            name: path,
            method: .get,
            path: path,
            scenarios: [scenario],
            activeScenarioID: scenario.id
        )
    }

    private func editor(
        endpoint: Endpoint,
        scenario: Scenario,
        writes: ScenarioWrites,
        statusCodeField: String,
        bodyField: String,
        headerFields: [(String, String)],
        sharing pendingEdits: EndpointEditorPendingEdits
    ) -> EndpointEditorView {
        EndpointEditorView(
            endpoint: endpoint,
            activeScenario: scenario,
            globalDelayMs: 0,
            actions: recording(into: writes),
            initialStatusCodeString: statusCodeField,
            initialResponseBody: bodyField,
            initialDelayString: "0",
            initialGroupTag: "",
            initialHeaders: headerFields,
            pendingEdits: pendingEdits
        )
    }

    // MARK: - Fixtures shared by the tests below

    private func makeFirstScenario() -> Scenario {
        makeScenario(
            statusCode: 201,
            headers: ["Content-Type": "application/json"],
            body: #"{"ok":true}"#
        )
    }

    private func makeSecondScenario() -> Scenario {
        makeScenario(statusCode: 500, headers: [:], body: #"{"error":"boom"}"#)
    }

    // MARK: - Losing the edit

    @Test("A body still settling when the selection moves reaches the endpoint it was typed into")
    func aSettlingBodyReachesTheEndpointItWasTypedInto() {
        let firstScenario = makeFirstScenario()
        let secondScenario = makeSecondScenario()
        let first = makeEndpoint(path: "/first", scenario: firstScenario)
        let second = makeEndpoint(path: "/second", scenario: secondScenario)
        let firstWrites = ScenarioWrites()
        let secondWrites = ScenarioWrites()
        let pendingEdits = EndpointEditorPendingEdits()

        let editingFirst = editor(
            endpoint: first,
            scenario: firstScenario,
            writes: firstWrites,
            statusCodeField: "201",
            bodyField: #"{"ok":false}"#,
            headerFields: [("Content-Type", "application/json")],
            sharing: pendingEdits
        )
        // The keystroke. The 300ms starts here and nothing has been written yet.
        editingFirst.debounceBody()

        // The click, inside that window. The editor is rebuilt around the endpoint that was
        // selected, so the handler runs on a view value that already addresses the new one.
        let showingSecond = editor(
            endpoint: second,
            scenario: secondScenario,
            writes: secondWrites,
            statusCodeField: "500",
            bodyField: #"{"error":"boom"}"#,
            headerFields: [],
            sharing: pendingEdits
        )
        showingSecond.endpointSelectionChanged()

        #expect(firstWrites.bodies == [#"{"ok":false}"#])
        // The other half, and the one a flush that read `actions` off the current view would fail:
        // losing the edit is a bug, moving it onto the endpoint the user clicked is a worse one.
        #expect(secondWrites.bodies.isEmpty)
        #expect(secondWrites.statusCodes.isEmpty)
        #expect(secondWrites.headers.isEmpty)
    }

    @Test("Every debounced field is finished, not only the one last touched")
    func everyDebouncedFieldIsFinished() {
        let firstScenario = makeFirstScenario()
        let secondScenario = makeSecondScenario()
        let first = makeEndpoint(path: "/first", scenario: firstScenario)
        let second = makeEndpoint(path: "/second", scenario: secondScenario)
        let firstWrites = ScenarioWrites()
        let secondWrites = ScenarioWrites()
        let pendingEdits = EndpointEditorPendingEdits()

        let editingFirst = editor(
            endpoint: first,
            scenario: firstScenario,
            writes: firstWrites,
            statusCodeField: "404",
            bodyField: #"{"ok":false}"#,
            headerFields: [("X-Trace", "abc")],
            sharing: pendingEdits
        )
        editingFirst.debounceStatusCode()
        editingFirst.debounceHeaders()
        editingFirst.debounceBody()

        let showingSecond = editor(
            endpoint: second,
            scenario: secondScenario,
            writes: secondWrites,
            statusCodeField: "500",
            bodyField: #"{"error":"boom"}"#,
            headerFields: [],
            sharing: pendingEdits
        )
        showingSecond.endpointSelectionChanged()

        #expect(firstWrites.statusCodes == [404])
        #expect(firstWrites.headers == [["X-Trace": "abc"]])
        #expect(firstWrites.bodies == [#"{"ok":false}"#])
        #expect(secondWrites.statusCodes.isEmpty)
        #expect(secondWrites.headers.isEmpty)
        #expect(secondWrites.bodies.isEmpty)
    }

    @Test("Moving the selection without having typed writes nothing")
    func movingTheSelectionWithoutTypingWritesNothing() {
        // The negative control for the two above. Every field holds exactly what the model holds, so
        // the `…IsDirty` guards decline to schedule and there is nothing for the flush to find — a
        // flush that wrote whatever the fields said would turn every click into an edit.
        let firstScenario = makeFirstScenario()
        let secondScenario = makeSecondScenario()
        let first = makeEndpoint(path: "/first", scenario: firstScenario)
        let second = makeEndpoint(path: "/second", scenario: secondScenario)
        let firstWrites = ScenarioWrites()
        let secondWrites = ScenarioWrites()
        let pendingEdits = EndpointEditorPendingEdits()

        let editingFirst = editor(
            endpoint: first,
            scenario: firstScenario,
            writes: firstWrites,
            statusCodeField: "201",
            bodyField: #"{"ok":true}"#,
            headerFields: [("Content-Type", "application/json")],
            sharing: pendingEdits
        )
        editingFirst.debounceStatusCode()
        editingFirst.debounceHeaders()
        editingFirst.debounceBody()

        let showingSecond = editor(
            endpoint: second,
            scenario: secondScenario,
            writes: secondWrites,
            statusCodeField: "500",
            bodyField: #"{"error":"boom"}"#,
            headerFields: [],
            sharing: pendingEdits
        )
        showingSecond.endpointSelectionChanged()

        #expect(firstWrites.statusCodes.isEmpty)
        #expect(firstWrites.headers.isEmpty)
        #expect(firstWrites.bodies.isEmpty)
        #expect(secondWrites.statusCodes.isEmpty)
        #expect(secondWrites.headers.isEmpty)
        #expect(secondWrites.bodies.isEmpty)
    }

    // MARK: - The timer that was there all along

    @Test("An edit left alone commits on its own")
    func aSettledEditCommitsOnItsOwn() async throws {
        let firstScenario = makeFirstScenario()
        let first = makeEndpoint(path: "/first", scenario: firstScenario)
        let firstWrites = ScenarioWrites()

        let editingFirst = editor(
            endpoint: first,
            scenario: firstScenario,
            writes: firstWrites,
            statusCodeField: "201",
            bodyField: #"{"ok":false}"#,
            headerFields: [("Content-Type", "application/json")],
            sharing: EndpointEditorPendingEdits()
        )
        editingFirst.debounceBody()

        // Twice the settling time. Nothing here waits on a signal, because the thing being checked
        // is that a wall-clock timer nobody prompted still lands the write.
        try await Task.sleep(for: .milliseconds(600))

        #expect(firstWrites.bodies == [#"{"ok":false}"#])
    }

    @Test("A value committed on Return is not written a second time when the timer comes round")
    func committingOnReturnRetiresTheTimerItBeat() async throws {
        let firstScenario = makeFirstScenario()
        let first = makeEndpoint(path: "/first", scenario: firstScenario)
        let firstWrites = ScenarioWrites()

        let editingFirst = editor(
            endpoint: first,
            scenario: firstScenario,
            writes: firstWrites,
            statusCodeField: "201",
            bodyField: #"{"ok":false}"#,
            headerFields: [("Content-Type", "application/json")],
            sharing: EndpointEditorPendingEdits()
        )
        editingFirst.debounceBody()
        editingFirst.commitBody()

        try await Task.sleep(for: .milliseconds(600))

        #expect(firstWrites.bodies == [#"{"ok":false}"#])
    }
}
