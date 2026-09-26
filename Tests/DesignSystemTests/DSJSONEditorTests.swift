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

    @Test("Valid top-level JSON scalars do not show a syntax warning")
    func validJSONScalars() {
        for scalar in ["42", "true", #""ok""#, "null"] {
            #expect(DSJSONEditor.validateJSON(scalar))
            #expect(DSJSONEditor.validationErrorMessage(
                text: scalar, isValid: DSJSONEditor.validateJSON(scalar)
            ) == nil)
        }
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

        let aIndex = try #require(result.range(of: "\"a\""))
        let bIndex = try #require(result.range(of: "\"b\""))
        #expect(bIndex.lowerBound < aIndex.lowerBound)
    }

    @Test("Format preserves Unicode string contents and number spelling")
    func prettyPrintPreservesLiteralBytes() throws {
        let source = "{\"\u{0301}key\":\"\u{0301} a:b [c]\",\"number\":1.2300e+04,\"text\":\"e\u{0301}\"}"
        let expected = """
        {
          "\u{0301}key": "\u{0301} a:b [c]",
          "number": 1.2300e+04,
          "text": "e\u{0301}"
        }
        """

        #expect(DSJSONEditor.validateJSON(source))
        let formatted = try #require(DSJSONEditor.prettyPrint(source))
        #expect(Array(formatted.utf8) == Array(expected.utf8))
        #expect(DSJSONEditor.validateJSON(formatted))
    }

    @Test("Pretty-print refuses malformed and non-JSON text")
    func prettyPrintInvalid() {
        #expect(DSJSONEditor.prettyPrint("hello") == nil)
        #expect(DSJSONEditor.prettyPrint("<html><body>hi</body></html>") == nil)
        #expect(DSJSONEditor.prettyPrint("{invalid}") == nil)
        #expect(DSJSONEditor.prettyPrint(#"{"missing": "closing""#) == nil)
        #expect(DSJSONEditor.prettyPrint("[1,,2]") == nil)
    }

    @Test("Valid JSON scalars need no structural reflow")
    func prettyPrintScalars() {
        #expect(DSJSONEditor.prettyPrint("42") == nil)
        #expect(DSJSONEditor.prettyPrint("true") == nil)
        #expect(DSJSONEditor.prettyPrint(#""ok""#) == nil)
        #expect(DSJSONEditor.prettyPrint("null") == nil)
    }

    @Test("Valid deep JSON cannot be formatted past the output budget")
    func prettyPrintDeepJSON() {
        let depth = 400
        let compact = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)

        #expect(DSJSONEditor.validateJSON(compact))
        #expect(DSJSONEditor.prettyPrint(compact) == nil)
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

    @Test("Cancelled validation does not start a parse or publish a result")
    @MainActor
    func cancelledValidationSkipsWork() async {
        var callbacks: [Bool] = []
        let validation = Task {
            await DSJSONEditor.resolvedValidationResult(
                for: #"{"ok":true}"#,
                sleep: { _ in },
                validate: { _ in
                    Issue.record("A cancelled editor validation must not start parsing")
                    return true
                },
                onValidationChanged: { callbacks.append($0) }
            )
        }
        validation.cancel()

        #expect(await validation.value == nil)
        #expect(callbacks.isEmpty)
    }

    @Test("Cancellation during a parse suppresses the obsolete result")
    @MainActor
    func cancellationDuringValidationDoesNotPublish() async {
        var callbacks: [Bool] = []
        let validation = Task {
            await DSJSONEditor.resolvedValidationResult(
                for: #"{"ok":true}"#,
                sleep: { _ in },
                validate: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                },
                onValidationChanged: { callbacks.append($0) }
            )
        }

        #expect(await validation.value == nil)
        #expect(callbacks.isEmpty)
    }
}

@Suite("DSJSONEditor sizing")
struct DSJSONEditorSizingTests {

    // MARK: - Counting lines

    @Test("An empty document is one line, not none")
    func emptyDocumentIsOneLine() {
        #expect(DSJSONEditor.lineCount(of: "") == 1)
    }

    @Test("A line count is separators plus one")
    func lineCountIsSeparatorsPlusOne() {
        #expect(DSJSONEditor.lineCount(of: "{}") == 1)
        #expect(DSJSONEditor.lineCount(of: "{\n}") == 2)
        #expect(DSJSONEditor.lineCount(of: "{\n  \"a\": 1\n}") == 3)
    }

    @Test("Every newline the editor's own line map honours is counted")
    func lineCountHonoursEveryNewlineSeparator() {
        #expect(DSJSONEditor.lineCount(of: "a\r\nb\r\nc\r\nd") == 4)
        #expect(DSJSONEditor.lineCount(of: "a\rb") == 2)
        #expect(DSJSONEditor.lineCount(of: "a\u{2028}b") == 2)
        #expect(DSJSONEditor.lineCount(of: "a\u{2029}b") == 2)
        #expect(DSJSONEditor.lineCount(of: "a\u{0085}b") == 2)

        #expect(DSJSONEditor.lineCount(of: "a\r\nb") == DSJSONEditor.lineCount(of: "a\nb"))
    }

    @Test("A CRLF payload gets the height its lines deserve")
    func crlfPayloadIsNotSizedToOneLine() {
        let crlf = (0..<20).map { "  \"key\($0)\": \($0)" }.joined(separator: "\r\n")

        #expect(DSJSONEditor.lineCount(of: crlf) == 20)
        #expect(DSJSONEditor.height(forLines: DSJSONEditor.lineCount(of: crlf))
                > DSJSONEditor.height(forLines: 1))
    }

    @Test("A trailing newline opens a line rather than closing one")
    func trailingNewlineOpensALine() {
        #expect(DSJSONEditor.lineCount(of: "{}\n") == 2)
    }

    // MARK: - Turning lines into a height

    @Test("Height grows with the line count, and never reports zero")
    func heightGrowsWithLines() {
        let one = DSJSONEditor.height(forLines: 1)
        let five = DSJSONEditor.height(forLines: 5)

        #expect(one > 0)
        #expect(five > one)
        #expect(abs(five - one * 5) < 0.001)
    }

    @Test("A line count below one is floored rather than negated")
    func lineCountBelowOneIsFloored() {
        #expect(DSJSONEditor.height(forLines: 0) == DSJSONEditor.height(forLines: 1))
        #expect(DSJSONEditor.height(forLines: -3) == DSJSONEditor.height(forLines: 1))
    }

    @Test("One line of SF Mono at 13pt is a plausible line height")
    func oneLineIsAPlausibleHeight() {
        let height = DSJSONEditor.height(forLines: 1)
        #expect(height >= 12)
        #expect(height <= 22)
    }

    @Test("The two themes are built from one face")
    func themesShareOneFace() {
        #expect(DSJSONEditor.editorFontName == "SFMono-Regular")
        #expect(DSJSONEditor.editorFontSize == 13)
    }
}

@Suite("DSColors")
struct DSColorsTests {

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

    @Test("httpStatusColor returns the secondary label for other codes")
    func httpStatusOther() {
        #expect(DSColors.httpStatusColor(for: 100) == DSColors.labelSecondary)
        #expect(DSColors.httpStatusColor(for: 600) == DSColors.labelSecondary)
    }

    @Test("methodColor maps common HTTP verbs and falls back for unknown values")
    func methodColors() {
        #expect(DSColors.methodColor(for: "GET") != DSColors.labelSecondary)
        #expect(DSColors.methodColor(for: "post") != DSColors.labelSecondary)
        #expect(DSColors.methodColor(for: "PUT") != DSColors.labelSecondary)
        #expect(DSColors.methodColor(for: "PATCH") != DSColors.labelSecondary)
        #expect(DSColors.methodColor(for: "DELETE") != DSColors.labelSecondary)
        #expect(DSColors.methodColor(for: "HEAD") != DSColors.labelSecondary)
        #expect(DSColors.methodColor(for: "OPTIONS") != DSColors.labelSecondary)
        #expect(DSColors.methodColor(for: "TRACE") == DSColors.labelSecondary)
    }
}

@Suite("DSPlainButtonStyle states")
struct DSPlainButtonStyleTests {

    @Test("The three states are three different washes")
    func statesAreDistinct() {
        let rest = DSPlainButtonStyle.wash(isPressed: false, isHovered: false)
        let hover = DSPlainButtonStyle.wash(isPressed: false, isHovered: true)
        let pressed = DSPlainButtonStyle.wash(isPressed: true, isHovered: false)

        #expect(rest != hover)
        #expect(hover != pressed)
        #expect(rest != pressed)
    }

    @Test("Pressing wins over hovering")
    func pressedWinsOverHovered() {
        #expect(DSPlainButtonStyle.wash(isPressed: true, isHovered: true)
                == DSPlainButtonStyle.wash(isPressed: true, isHovered: false))
    }

    @Test("Rest is clear, so a row and a button agree about not-hovered")
    func restIsClear() {
        #expect(DSPlainButtonStyle.wash(isPressed: false, isHovered: false) == Color.clear)
    }

    @Test("Both states reuse existing accent rungs rather than minting new ones")
    func statesReuseAccentRungs() {
        #expect(DSPlainButtonStyle.wash(isPressed: false, isHovered: true) == DSColors.accentSubtle)
        #expect(DSPlainButtonStyle.wash(isPressed: true, isHovered: false) == DSColors.accentMuted)
    }
}
