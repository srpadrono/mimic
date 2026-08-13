import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("DSJSONEditor validation")
struct DSJSONEditorTests {
    // MARK: - validateJSON

    @Test("Empty string is valid")
    func emptyStringIsValid() {
        #expect(DSJSONEditor.validateJSON(""))
    }

    @Test("Valid JSON object")
    func validJSONObject() {
        #expect(DSJSONEditor.validateJSON(#"{"key": "value"}"#))
    }

    @Test("Valid JSON array")
    func validJSONArray() {
        #expect(DSJSONEditor.validateJSON(#"[1, 2, 3]"#))
    }

    @Test("Valid nested JSON")
    func validNestedJSON() {
        let json = """
        {
          "id": 1,
          "name": "Test",
          "tags": ["a", "b"],
          "nested": {"key": true}
        }
        """
        #expect(DSJSONEditor.validateJSON(json))
    }

    @Test("Invalid JSON returns false")
    func invalidJSON() {
        #expect(DSJSONEditor.validateJSON("{invalid}") == false)
    }

    @Test("Incomplete JSON returns false")
    func incompleteJSON() {
        #expect(DSJSONEditor.validateJSON(#"{"key":"#) == false)
    }

    @Test("Plain string is invalid JSON")
    func plainStringIsInvalid() {
        #expect(DSJSONEditor.validateJSON("hello") == false)
    }

    // MARK: - prettyPrint

    @Test("Pretty-prints compact JSON without reordering its keys")
    func prettyPrintCompact() throws {
        let compact = #"{"b":2,"a":1}"#
        let result = try #require(DSJSONEditor.prettyPrint(compact))
        #expect(result.contains("\n"))

        // This assertion used to read `aIndex < bIndex` — it asserted the *bug*. The old
        // implementation round-tripped through `JSONSerialization` with `.sortedKeys`, and because
        // this is the editor's Format button, the alphabetised text was saved back as the response
        // body the server then served. A mock written to mirror a real payload came back rearranged.
        let aIndex = try #require(result.range(of: "\"a\""))
        let bIndex = try #require(result.range(of: "\"b\""))
        #expect(bIndex.lowerBound < aIndex.lowerBound)
    }

    @Test("Pretty-print leaves text that is not JSON alone")
    func prettyPrintInvalid() {
        // Anything not opening with a brace or bracket is refused outright. Text that *does* open
        // like JSON but is malformed still gets re-indented, deliberately: the scanner never
        // reparses, so a truncated body still formats where a parser would refuse. The Format button
        // is not reachable in that state anyway — `canFormatBody` gates on `isJSONValid`.
        #expect(DSJSONEditor.prettyPrint("hello") == nil)
        #expect(DSJSONEditor.prettyPrint("<html><body>hi</body></html>") == nil)
    }

    @Test("Pretty-print returns nil for empty string")
    func prettyPrintEmpty() {
        #expect(DSJSONEditor.prettyPrint("") == nil)
    }

    @Test("Validation error message only appears for invalid non-empty content")
    func validationErrorMessage() {
        #expect(DSJSONEditor.validationErrorMessage(text: "", isValid: false) == nil)
        #expect(DSJSONEditor.validationErrorMessage(text: #"{"ok":true}"#, isValid: true) == nil)
        #expect(
            DSJSONEditor.validationErrorMessage(text: "{invalid}", isValid: false)
            == "Not valid JSON \u{2014} it is still saved and served exactly as written."
        )
    }

    @Test("Async validation matches synchronous validation")
    func validateAsync() async {
        let valid = await DSJSONEditor.validateAsync(#"{"count":2}"#)
        let invalid = await DSJSONEditor.validateAsync("{invalid}")

        #expect(valid)
        #expect(invalid == false)
    }

    @Test("Resolved validation result reports success and cancellation")
    @MainActor
    func resolvedValidationResult() async {
        var callbackValues: [Bool] = []

        let success = await DSJSONEditor.resolvedValidationResult(
            for: #"{"ok":true}"#,
            sleep: { _ in },
            validate: { _ in true },
            onValidationChanged: { callbackValues.append($0) }
        )
        let cancelled = await DSJSONEditor.resolvedValidationResult(
            for: "{invalid}",
            sleep: { _ in throw CancellationError() },
            validate: { _ in false }
        )

        #expect(success == true)
        #expect(callbackValues == [true])
        #expect(cancelled == nil)
    }

    @Test("Resolved validation result uses the default async validator")
    @MainActor
    func resolvedValidationResultWithDefaultValidator() async {
        let valid = await DSJSONEditor.resolvedValidationResult(
            for: #"{"ok":true}"#,
            sleep: { _ in }
        )
        let invalid = await DSJSONEditor.resolvedValidationResult(
            for: "{invalid}",
            sleep: { _ in }
        )

        #expect(valid == true)
        #expect(invalid == false)
    }
}

// MARK: - DSColors tests

@Suite("DSColors")
struct DSColorsTests {

    // Each arm returns the *text* variant, not the base semantic token. A pill draws this colour as
    // its label and, at 12%, as its own fill, and the base tokens do not survive that composite —
    // `DSContrastTests.statusPillTextClearsAAOnItsOwnFill` is where that is measured. These four
    // tests pin the boundaries of each range; the palette question is settled next door.

    @Test("httpStatusColor returns the success text color for 2xx")
    func httpStatus2xx() {
        let expected = DSColors.successText
        #expect(DSColors.httpStatusColor(for: 200) == expected)
        #expect(DSColors.httpStatusColor(for: 201) == expected)
        #expect(DSColors.httpStatusColor(for: 299) == expected)
    }

    @Test("httpStatusColor returns the accent text color for 3xx")
    func httpStatus3xx() {
        let expected = DSColors.accentText
        #expect(DSColors.httpStatusColor(for: 301) == expected)
        #expect(DSColors.httpStatusColor(for: 302) == expected)
        #expect(DSColors.httpStatusColor(for: 399) == expected)
    }

    @Test("httpStatusColor returns the warning text color for 4xx")
    func httpStatus4xx() {
        let expected = DSColors.warningText
        #expect(DSColors.httpStatusColor(for: 400) == expected)
        #expect(DSColors.httpStatusColor(for: 404) == expected)
        #expect(DSColors.httpStatusColor(for: 499) == expected)
    }

    @Test("httpStatusColor returns the destructive text color for 5xx")
    func httpStatus5xx() {
        let expected = DSColors.destructiveText
        #expect(DSColors.httpStatusColor(for: 500) == expected)
        #expect(DSColors.httpStatusColor(for: 503) == expected)
        #expect(DSColors.httpStatusColor(for: 599) == expected)
    }

    @Test("httpStatusColor returns secondary for other codes")
    func httpStatusOther() {
        #expect(DSColors.httpStatusColor(for: 100) == .secondary)
        #expect(DSColors.httpStatusColor(for: 600) == .secondary)
    }

    @Test("methodColor maps common HTTP verbs and falls back for unknown values")
    func methodColors() {
        #expect(DSColors.methodColor(for: "GET") != .secondary)
        #expect(DSColors.methodColor(for: "post") != .secondary)
        #expect(DSColors.methodColor(for: "PUT") != .secondary)
        #expect(DSColors.methodColor(for: "PATCH") != .secondary)
        #expect(DSColors.methodColor(for: "DELETE") != .secondary)
        #expect(DSColors.methodColor(for: "HEAD") != .secondary)
        #expect(DSColors.methodColor(for: "OPTIONS") != .secondary)
        #expect(DSColors.methodColor(for: "TRACE") == .secondary)
    }
}

// MARK: - DSServerState tests

@Suite("DSServerState")
struct DSServerStateTests {

    @Test("Labels are correct")
    func labels() {
        #expect(DSServerState.idle.label == "Idle")
        #expect(DSServerState.running.label == "Running")
        #expect(DSServerState.stopped.label == "Stopped")
        #expect(DSServerState.error.label == "Error")
    }

    @Test("Idle and stopped share the same color")
    func idleAndStoppedSameColor() {
        #expect(DSServerState.idle.color == DSServerState.stopped.color)
    }

    @Test("Running color is green")
    func runningIsGreen() {
        #expect(DSServerState.running.color == DSColors.serverRunning)
    }

    @Test("Error color is red")
    func errorIsRed() {
        #expect(DSServerState.error.color == DSColors.serverError)
    }
}

// MARK: - Removed: `DSPanelHeaderTests`
//
// Two cases lived here and neither could fail.
//
// `headerHeightIsShared` asserted `DSPanelHeader<EmptyView>.height == DSPanelHeader<Text>.height`
// and `> 0`. `height` is a `static var` returning `DSBarHeight.panelHeader`, so the two generic
// specialisations read the same stored constant: the comparison is `x == x`, true for every possible
// value of the token, including a value that would break every panel in the window. The `> 0`
// companion excluded zero and negatives and nothing else.
//
// `headerRenders` constructed two `DSPanelHeader` values into `_` and asserted nothing at all. A
// `View` initialiser stores its arguments; it does not lay anything out, so the only way that case
// could have failed is by trapping inside a memberwise assignment.
//
// The claims they were reaching for are made properly in `DSComponentRenderingTests`, which is where
// the hosting harness that can actually measure a view lives:
//
// - `laddersArePinned` pins `DSBarHeight.panelHeader == 30` — the assertion an equality between two
//   reads of one constant cannot make — and `DSPanelHeader<EmptyView>.height ==
//   DSBarHeight.panelHeader`, so the view keeps taking its number from the ladder.
// - `panelChromeSharesOneHeight` renders a bare header, a header *with* a subtitle and a trailing
//   `DSPanelHeaderButton`, and a `DSTabStrip`, and measures all three against a `Color` fixed to the
//   token. That is `headerRenders`'s intent — both shapes survive layout — plus the cross-panel
//   alignment neither case here checked.
//
// Nothing is left to move, which is why this file now ends at `DSServerStateTests`.
