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

@Suite("DSJSONEditor sizing")
struct DSJSONEditorSizingTests {

    // MARK: - Counting lines

    @Test("An empty document is one line, not none")
    func emptyDocumentIsOneLine() {
        // An empty editor still shows a caret sitting on a line, so zero would size the well to
        // nothing and there would be nowhere to start typing.
        #expect(DSJSONEditor.lineCount(of: "") == 1)
    }

    @Test("A line count is separators plus one")
    func lineCountIsSeparatorsPlusOne() {
        #expect(DSJSONEditor.lineCount(of: "{}") == 1)
        #expect(DSJSONEditor.lineCount(of: "{\n}") == 2)
        #expect(DSJSONEditor.lineCount(of: "{\n  \"a\": 1\n}") == 3)
    }

    @Test("A trailing newline opens a line rather than closing one")
    func trailingNewlineOpensALine() {
        // The caret sits *after* the separator, on a line of its own, and the well has to have room
        // for it. Counting separators alone would leave the caret against the bottom edge.
        #expect(DSJSONEditor.lineCount(of: "{}\n") == 2)
    }

    // MARK: - Turning lines into a height

    @Test("Height grows with the line count, and never reports zero")
    func heightGrowsWithLines() {
        let one = DSJSONEditor.height(forLines: 1)
        let five = DSJSONEditor.height(forLines: 5)

        #expect(one > 0)
        #expect(five > one)
        // Linear in the line count: five lines is five times one line, because every line is laid
        // out at the same height. A ratio rather than a literal, so a font-metrics change moves both
        // sides together instead of failing on a number nobody chose.
        #expect(abs(five - one * 5) < 0.001)
    }

    @Test("A line count below one is floored rather than negated")
    func lineCountBelowOneIsFloored() {
        // Defensive: a caller subtracting its way to zero should get one line's worth of well, not a
        // zero-height frame or — with a negative — an inverted one that traps in layout.
        #expect(DSJSONEditor.height(forLines: 0) == DSJSONEditor.height(forLines: 1))
        #expect(DSJSONEditor.height(forLines: -3) == DSJSONEditor.height(forLines: 1))
    }

    @Test("One line of SF Mono at 12pt is a plausible line height")
    func oneLineIsAPlausibleHeight() {
        // Deliberately a range, not a number. The point is that the measurement comes from the font
        // rather than from a literal, so pinning it exactly would fail on a metrics change that is
        // not a regression. Outside this range something has gone wrong — a missing face falling
        // back to a display font, or a size read from the wrong theme.
        let height = DSJSONEditor.height(forLines: 1)
        #expect(height >= 12)
        #expect(height <= 22)
    }

    @Test("The two themes are built from one face")
    func themesShareOneFace() {
        // The font name and size were written twice, once per theme. They are constants now, and
        // `height(forLines:)` measures that same face — so a size that moved in one appearance and
        // not the other would put the well's height and the text inside it out of step.
        #expect(DSJSONEditor.editorFontName == "SFMono-Regular")
        #expect(DSJSONEditor.editorFontSize == 12)
    }
}

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

// MARK: - Removed: `DSServerStateTests`

// Four cases over `DSServerState`: its four labels, and the colour each state mapped to.
//
// The type is gone, and the suite is the reason it is worth saying why here rather than only in
// `DSColors`. `DSServerState`'s only consumer was `DSStatusBadge`, which nothing in the window
// drew — so a green suite over it was evidence about code the user never ran, which is the shape of
// failure this repository has already paid for once at module scale. Three of the four cases also
// restated a switch arm as an equality against the very token that arm returns.
//
// `DSColors` carries the note on what bringing the type back would have to answer first: five
// states rather than four, since the server this app runs can be starting and stopping.

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
// Nothing is left to move, which is why this file now ends at `DSColorsTests` and two notes about
// what used to follow it.
