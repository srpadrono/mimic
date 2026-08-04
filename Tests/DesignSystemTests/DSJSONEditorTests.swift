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
        #expect(!DSJSONEditor.validateJSON("{invalid}"))
    }

    @Test("Incomplete JSON returns false")
    func incompleteJSON() {
        #expect(!DSJSONEditor.validateJSON(#"{"key":"#))
    }

    @Test("Plain string is invalid JSON")
    func plainStringIsInvalid() {
        #expect(!DSJSONEditor.validateJSON("hello"))
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

    @Test("httpStatusColor returns success color for 2xx")
    func httpStatus2xx() {
        let expected = DSColors.success
        #expect(DSColors.httpStatusColor(for: 200) == expected)
        #expect(DSColors.httpStatusColor(for: 201) == expected)
        #expect(DSColors.httpStatusColor(for: 299) == expected)
    }

    @Test("httpStatusColor returns accent color for 3xx")
    func httpStatus3xx() {
        let expected = DSColors.accent
        #expect(DSColors.httpStatusColor(for: 301) == expected)
        #expect(DSColors.httpStatusColor(for: 302) == expected)
        #expect(DSColors.httpStatusColor(for: 399) == expected)
    }

    @Test("httpStatusColor returns warning color for 4xx")
    func httpStatus4xx() {
        let expected = DSColors.warning
        #expect(DSColors.httpStatusColor(for: 400) == expected)
        #expect(DSColors.httpStatusColor(for: 404) == expected)
        #expect(DSColors.httpStatusColor(for: 499) == expected)
    }

    @Test("httpStatusColor returns destructive color for 5xx")
    func httpStatus5xx() {
        let expected = DSColors.destructive
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

@Suite("DSDrawerDivider")
struct DSDrawerDividerTests {
    @Test("Divider visual helpers reflect dragging and hover state")
    func dividerVisualHelpers() {
        #expect(DSDrawerDivider.lineThickness(isDragging: false) == 1)
        #expect(DSDrawerDivider.lineThickness(isDragging: true) == 2.5)
        #expect(DSDrawerDivider.lineColor(isDragging: true, isHovered: false) == DSColors.accent)
        #expect(DSDrawerDivider.lineColor(isDragging: false, isHovered: true) == DSColors.accent.opacity(0.6))
        #expect(DSDrawerDivider.lineColor(isDragging: false, isHovered: false) == DSColors.panelSeparator)
    }

    @Test("Divider drag delta and clamping account for edge direction")
    func dividerDragDeltaAndClamping() {
        #expect(DSDrawerDivider.dragDelta(translation: CGSize(width: 24, height: 10), edge: .leading) == 24)
        #expect(DSDrawerDivider.dragDelta(translation: CGSize(width: 24, height: 10), edge: .trailing) == -24)
        #expect(DSDrawerDivider.dragDelta(translation: CGSize(width: 8, height: 16), edge: .top) == 16)
        #expect(DSDrawerDivider.dragDelta(translation: CGSize(width: 8, height: 16), edge: .bottom) == -16)
        #expect(DSDrawerDivider.clampedSize(startingAt: 120, delta: -200, maxSize: 300) == 0)
        #expect(DSDrawerDivider.clampedSize(startingAt: 120, delta: 250, maxSize: 300) == 300)
        #expect(DSDrawerDivider.clampedSize(startingAt: 120, delta: 30, maxSize: 300) == 150)
    }

    @Test("Divider drag state tracks first and subsequent drags")
    func dividerDragChangeState() {
        let firstDrag = DSDrawerDivider.dragChangeState(
            isDragging: false,
            currentSize: 180,
            dragStartSize: 0,
            translation: CGSize(width: 40, height: 0),
            edge: .leading,
            maxSize: 260
        )
        #expect(firstDrag.isDragging)
        #expect(firstDrag.dragStartSize == 180)
        #expect(firstDrag.size == 220)

        let continuedDrag = DSDrawerDivider.dragChangeState(
            isDragging: true,
            currentSize: firstDrag.size,
            dragStartSize: firstDrag.dragStartSize,
            translation: CGSize(width: -300, height: 0),
            edge: .leading,
            maxSize: 260
        )
        #expect(continuedDrag.dragStartSize == 180)
        #expect(continuedDrag.size == 0)
    }

    @Test("Divider drag end snaps closed, to minimum, or keeps size")
    func dividerDragEndState() {
        let closed = DSDrawerDivider.dragEndState(
            size: 40,
            minSize: 120,
            defaultSize: 180,
            snapCloseThreshold: 72
        )
        #expect(closed.size == 180)
        #expect(closed.isPresented == false)
        #expect(closed.shouldSnapToMinimum == false)

        let snapped = DSDrawerDivider.dragEndState(
            size: 100,
            minSize: 120,
            defaultSize: 180,
            snapCloseThreshold: 72
        )
        #expect(snapped.size == 100)
        #expect(snapped.isPresented == nil)
        #expect(snapped.shouldSnapToMinimum)

        let retained = DSDrawerDivider.dragEndState(
            size: 180,
            minSize: 120,
            defaultSize: 180,
            snapCloseThreshold: 72
        )
        #expect(retained.size == 180)
        #expect(retained.isPresented == nil)
        #expect(retained.shouldSnapToMinimum == false)
    }

    @Test("Divider hover and resolved drag helpers stay consistent")
    func dividerAdditionalHelpers() {
        #expect(DSDrawerDivider.handleHover(hovering: true, axis: .horizontal))
        #expect(DSDrawerDivider.handleHover(hovering: false, axis: .vertical) == false)

        let resolved = DSDrawerDivider.resolvedDragEnd(size: 60, minSize: 120, defaultSize: 180)
        #expect(resolved.size == 180)
        #expect(resolved.isPresented == false)
        #expect(resolved.shouldSnapToMinimum == false)
    }

    @Test("Divider interaction helpers update local state and bindings")
    @MainActor
    func dividerInteractionHelpers() {
        var size: CGFloat = 180
        var isPresented = true

        let divider = DSDrawerDivider(
            axis: .horizontal,
            size: Binding(get: { size }, set: { size = $0 }),
            isPresented: Binding(get: { isPresented }, set: { isPresented = $0 }),
            minSize: 120,
            maxSize: 240,
            defaultSize: 180,
            edge: .leading
        )

        divider.updateHoverState(true)

        divider.updateDragState(with: CGSize(width: 30, height: 0))
        #expect(size == 210)

        divider.finishDragging()
        #expect(size == 210)
        #expect(isPresented)

        divider.updateDragState(with: CGSize(width: -110, height: 0))
        divider.finishDragging()
        #expect(size == 120)

        divider.updateDragState(with: CGSize(width: -240, height: 0))
        divider.finishDragging()
        #expect(size == 180)
        #expect(isPresented == false)
    }
}

@Suite("Panel chrome")
struct DSPanelHeaderTests {

    @Test("Every panel header is the same height, so panels line up across the window")
    func headerHeightIsShared() {
        // The number matters less than the fact that there is exactly one of it. Before this, the
        // sidebar had no header, the request log had a tall one, and the inspector a third size.
        #expect(DSPanelHeader<EmptyView>.height == DSPanelHeader<Text>.height)
        #expect(DSPanelHeader<EmptyView>.height > 0)
    }

    @Test("A header renders with and without a trailing accessory")
    func headerRenders() {
        _ = DSPanelHeader("Request Log", subtitle: "9 requests", identifier: "test")
        _ = DSPanelHeader("Endpoints", identifier: "test") {
            DSPanelHeaderButton(systemImage: "plus", help: "Add", identifier: "test.add") { }
        }
    }

    @Test("The divider's hit target is far larger than the line it draws")
    func dividerHitTargetIsGrabbable() {
        // A 1pt line is fine to look at and miserable to grab; the target is what makes the panel
        // feel resizable.
        #expect(DSDrawerDivider.hitTargetThickness >= 8)
        #expect(DSDrawerDivider.hitTargetThickness > DSDrawerDivider.lineThickness(isDragging: true))
    }

    @Test("Snapping closed restores the panel's own default, not the size it was dragged to")
    func snapCloseRestoresTheRealDefault() {
        // The regression this pins: `defaultSize` used to be read from the live size binding inside
        // `init`. SwiftUI re-runs `init` on every body evaluation, so it always equalled the current
        // size — which made "restore the default" a no-op and reopened a snapped-shut panel at
        // whatever sliver it was dragged to.
        let result = DSDrawerDivider.dragEndState(
            size: 20,
            minSize: 120,
            defaultSize: 220,
            snapCloseThreshold: 72
        )
        #expect(result.isPresented == false)
        #expect(result.size == 220, "reopening must use the shipped default, not the dragged size")
    }
}
