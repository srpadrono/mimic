import Testing
import Domain
@testable import AppFeatures

/// The rules the endpoint editor commits by: which status codes it will serve and what it says
/// about the ones it will not, and — separately — whether a field is carrying an edit at all.
///
/// Both were bugs. A status code outside 200...599 used to be dropped in silence, and every field
/// filled in by `syncFromModel` used to look exactly like something a person had just typed, so
/// selecting an endpoint scheduled a write of the data it had that moment finished reading.
@Suite("Endpoint editor commits")
struct EndpointEditorCommitTests {

    private func makeScenario(
        statusCode: Int = 201,
        headers: [String: String] = ["Content-Type": "application/json", "X-Request-ID": "abc-123"],
        body: String? = #"{"ok":true}"#
    ) -> Scenario {
        Scenario(name: "Default", statusCode: statusCode, headers: headers, body: body)
    }

    private func makeEndpoint(scenario: Scenario) -> Endpoint {
        Endpoint(
            name: "Create User",
            method: .post,
            path: "/api/v1/users",
            scenarios: [scenario],
            activeScenarioID: scenario.id,
            delayMs: 125,
            groupTag: "Users"
        )
    }

    // MARK: - Status code boundaries

    @Test(
        "The serveable range runs from 200 to 599 inclusive",
        arguments: [200, 201, 204, 404, 500, 599]
    )
    func acceptsServeableCodes(code: Int) {
        #expect(EndpointEditorView.statusCodeValue(from: "\(code)") == code)
        #expect(EndpointEditorView.statusCodeValidationMessage(for: "\(code)") == nil)
    }

    @Test(
        "A code outside the range is refused, and says which range it is outside",
        // 199 and 600 are the two that matter: one either side of the edge. A 1xx is refused
        // because NIO treats an informational head as "more is coming" and the body that follows
        // trips an assertion — see `EndpointValidator.serveableStatusCodes`.
        arguments: ["199", "600", "100", "0", "1000", "-200"]
    )
    func rejectsUnserveableCodes(text: String) {
        #expect(EndpointEditorView.statusCodeValue(from: text) == nil)
        #expect(
            EndpointEditorView.statusCodeValidationMessage(for: text)
                == "Status code must be between 200 and 599"
        )
    }

    @Test(
        "Text that is not a number is refused the same way",
        // " 200" belongs here rather than with the valid codes: `Int(" 200")` is nil, so the field
        // as typed is not a number, and the message has to match what the commit actually did.
        arguments: ["abc", "20a", "2.5", " 200", "٢٠٠"]
    )
    func rejectsNonNumericText(text: String) {
        #expect(EndpointEditorView.statusCodeValue(from: text) == nil)
        #expect(
            EndpointEditorView.statusCodeValidationMessage(for: text)
                == "Status code must be between 200 and 599"
        )
    }

    @Test("An empty field is asked to be filled rather than corrected")
    func promptsForAnEmptyField() {
        // `NewProjectSheet` stays silent on an empty port, because a sheet applies nothing until it
        // is confirmed. This field is live: blank means the endpoint is still serving a code the
        // editor has stopped showing, which is the same divergence the message exists to name.
        #expect(EndpointEditorView.statusCodeValue(from: "") == nil)
        #expect(
            EndpointEditorView.statusCodeValidationMessage(for: "")
                == "Enter a status code between 200 and 599"
        )
    }

    @Test("Nothing is ever refused in silence")
    func everyRefusalHasAMessage() {
        // The invariant the defect broke, stated once: if the commit will not happen, the field has
        // something to show for it. A future change to either rule has to keep them agreeing.
        let inputs = ["", " ", "0", "99", "100", "199", "600", "1000", "abc", "2.5", "-1", "٢٠٠"]

        for input in inputs {
            #expect(
                EndpointEditorView.statusCodeValue(from: input) == nil,
                "\(input.debugDescription) should not be committable"
            )
            #expect(
                EndpointEditorView.statusCodeValidationMessage(for: input) != nil,
                "\(input.debugDescription) is refused, so it needs a message"
            )
        }

        for code in EndpointValidator.serveableStatusCodes {
            #expect(EndpointEditorView.statusCodeValidationMessage(for: "\(code)") == nil)
        }
    }

    // MARK: - What the model already holds

    @Test("Values the editor just read back from the model are not edits")
    func syncedValuesAreNotDirty() throws {
        // The defect in one test. `syncFromModel` assigns every field, each assignment trips an
        // `onChange`, and each handler used to schedule a write — of the data it had just read.
        let scenario = makeScenario()
        let endpoint = makeEndpoint(scenario: scenario)
        let synced = try #require(
            EndpointEditorView.syncedValues(endpoint: endpoint, activeScenario: scenario)
        )

        #expect(!EndpointEditorView.statusCodeIsDirty(synced.statusCodeString, against: scenario))
        #expect(!EndpointEditorView.bodyIsDirty(synced.responseBody, against: scenario))
        #expect(!EndpointEditorView.headersAreDirty(synced.headers, against: scenario))
    }

    @Test("A header list rebuilt with fresh identities still says the same thing")
    func rebuiltHeaderRowsAreNotDirty() {
        // Why the comparison cannot be `[HeaderEntry] == [HeaderEntry]`: every sync mints new
        // `id`s, so the array is never equal to the one it replaced even when the headers are.
        let scenario = makeScenario(headers: ["A": "1", "B": "2"])

        #expect(!EndpointEditorView.headersAreDirty([("A", "1"), ("B", "2")], against: scenario))
        // Order is a property of the rows, not of the headers.
        #expect(!EndpointEditorView.headersAreDirty([("B", "2"), ("A", "1")], against: scenario))
    }

    @Test("A row added but not yet typed into is not a header")
    func emptyHeaderRowIsNotDirty() {
        // "Add" appends a blank row. Committing at that point would write nothing new, so it should
        // not wake the debounce at all.
        let scenario = makeScenario(headers: ["A": "1"])

        #expect(!EndpointEditorView.headersAreDirty([("A", "1"), ("", "")], against: scenario))
        #expect(!EndpointEditorView.headersAreDirty([("A", "1"), ("   ", "value")], against: scenario))
    }

    @Test("A real edit is still an edit")
    func realEditsAreDirty() {
        let scenario = makeScenario(statusCode: 201, headers: ["A": "1"], body: #"{"ok":true}"#)

        #expect(EndpointEditorView.statusCodeIsDirty("404", against: scenario))
        #expect(EndpointEditorView.bodyIsDirty(#"{"ok":false}"#, against: scenario))
        #expect(EndpointEditorView.headersAreDirty([("A", "2")], against: scenario))
        #expect(EndpointEditorView.headersAreDirty([("A", "1"), ("B", "2")], against: scenario))
        // Removing the last header is an edit too — the shape that used to be written by index.
        #expect(EndpointEditorView.headersAreDirty([], against: scenario))
    }

    @Test("A cleared field is an edit, even though it will not be committed")
    func clearedStatusCodeIsDirty() {
        // Dirtiness and validity are separate questions. An emptied status code differs from the
        // model, so the debounce runs; it is the commit that refuses it, and the refusal is what
        // puts the message on screen.
        let scenario = makeScenario(statusCode: 201)

        #expect(EndpointEditorView.statusCodeIsDirty("", against: scenario))
        #expect(EndpointEditorView.statusCodeIsDirty("600", against: scenario))
        #expect(EndpointEditorView.statusCodeValue(from: "600") == nil)
    }

    @Test("An absent body and an empty one are the same body")
    func missingBodyReadsAsEmpty() {
        // `syncedValues` maps `nil` to "" and `bodyValue(from:)` maps "" back to `nil`, so an
        // endpoint with no body must not look permanently edited.
        let scenario = makeScenario(body: nil)

        #expect(!EndpointEditorView.bodyIsDirty("", against: scenario))
        #expect(EndpointEditorView.bodyIsDirty(" ", against: scenario))
        #expect(EndpointEditorView.bodyIsDirty("{}", against: scenario))
    }

    @Test("With no active scenario there is nothing to be dirty against")
    func nothingCommitsWithoutAScenario() {
        // The editor shows its empty state instead of the fields here, so this is a guard rather
        // than a behaviour: a commit would have nowhere to land.
        #expect(!EndpointEditorView.statusCodeIsDirty("404", against: nil))
        #expect(!EndpointEditorView.bodyIsDirty("{}", against: nil))
        #expect(!EndpointEditorView.headersAreDirty([("A", "1")], against: nil))
    }
}
