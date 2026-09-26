import AppKit
import Observation
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("Native body editing", .serialized)
@MainActor
struct DSNativeTextEditorTests {
    enum Surface: CaseIterable { case json, multiline }

    @Observable
    fileprivate final class Draft {
        var text: String
        var documentID = "first"
        var isFocused = false
        var editorHeight: CGFloat = 180
        init(_ text: String) { self.text = text }
    }

    private struct Harness: View {
        @Bindable var draft: Draft
        let surface: Surface

        var body: some View {
            switch surface {
            case .json:
                DSJSONEditor(text: $draft.text, identifier: "native-json", documentID: draft.documentID)
            case .multiline:
                DSMultilineField("Response body", text: $draft.text, height: draft.editorHeight, identifier: "native-multiline",
                                 isFocused: $draft.isFocused)
            }
        }
    }

    private func waitFor(_ description: String = "Native editor state did not settle", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            // Yield the MainActor so native undo notifications, SwiftUI and focus callbacks can run.
            try await Task.sleep(for: .milliseconds(10))
            if condition() { return }
        } while Date() < deadline
        try #require(condition(), "\(description) before the deadline")
    }

    private func withEditor(
        _ surface: Surface, text: String = "",
        inspect: (Draft, NSTextView, NSWindow) async throws -> Void
    ) async throws {
        let draft = Draft(text)
        let controller = NSHostingController(rootView: Harness(draft: draft, surface: surface))
        let container = NSViewController()
        container.view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 260))
        container.addChild(controller)
        controller.view.frame = container.view.bounds
        controller.view.autoresizingMask = [.width, .height]
        container.view.addSubview(controller.view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = container
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        var editor: NSTextView?
        try await waitFor {
            controller.view.layoutSubtreeIfNeeded()
            editor = DSNativeTextEditingSession.documentTextView(in: controller.view)
            return editor?.string == text
        }
        let textView = try #require(editor)
        #expect(window.makeFirstResponder(textView))
        #expect(window.firstResponder === textView)
        try await inspect(draft, textView, window)
    }

    @Test("External Format is one reversible edit after native typing", arguments: Surface.allCases)
    func formatUndoRedo(_ surface: Surface) async throws {
        let compact = #"{"long":"abcdef","items":[1,2]}"#
        let formatted = """
        {
          "long": "abcdef",
          "items": [
            1,
            2
          ]
        }
        """
        try await withEditor(surface) { draft, editor, window in
            editor.insertText(compact, replacementRange: NSRange(location: NSNotFound, length: 0))
            try await waitFor("Native paste did not update the draft") { draft.text == compact }
            let undo = try #require(editor.undoManager)
            editor.setSelectedRange(NSRange(location: 9, length: 6))

            draft.text = formatted
            try await waitFor("External formatting did not reach the native editor") { editor.string == formatted }
            undo.undo()
            try await waitFor("Undo did not restore the compact draft") { draft.text == compact }
            #expect(editor.string == compact)
            #expect(editor.selectedRange() == NSRange(location: 9, length: 6))

            undo.redo()
            try await waitFor("Redo did not restore the formatted draft") { draft.text == formatted }
            #expect(editor.string == formatted)
            undo.undo()
            try await waitFor("The second Undo did not restore the compact draft") { draft.text == compact }
            #expect(window.firstResponder === editor)
            undo.undo()
            #expect(editor.string.isEmpty, "Native undo must reverse the original paste")
            try await waitFor("Undo did not reverse the original native paste") { draft.text.isEmpty }
            #expect(editor.string.isEmpty, "Format must not corrupt the preceding native typing undo")
        }
    }

    @Test("Native typing stays coalesced across binding updates", arguments: Surface.allCases)
    func typingUndoGroup(_ surface: Surface) async throws {
        try await withEditor(surface) { draft, editor, window in
            let undo = try #require(editor.undoManager)
            var expected = ""
            for character in ["a", "b", "c"] {
                expected += character
                editor.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
                try await waitFor("Typing did not update the draft to \(expected)") { draft.text == expected }
            }
            #expect(draft.text == "abc")
            #expect(editor.isCoalescingUndo)
            #expect(window.firstResponder === editor)
            undo.undo()
            #expect(editor.string.isEmpty, "Native undo must reverse the coalesced typing")
            try await waitFor("Undo did not reverse the coalesced typing") { draft.text.isEmpty }
            #expect(editor.string.isEmpty)
            undo.redo()
            #expect(editor.string == "abc")
            try await waitFor("Redo did not restore the coalesced typing draft") { draft.text == "abc" }
        }
    }

    @Test("A shorter external body clamps the native UTF-16 selection", arguments: Surface.allCases)
    func shorterReplacementClampsSelection(_ surface: Surface) async throws {
        try await withEditor(surface, text: #"{"long":"abcdef","items":[1,2]}"#) { draft, editor, _ in
            editor.setSelectedRange(NSRange(location: 20, length: 5))
            draft.text = "😀"
            try await waitFor { editor.string == "😀" }
            #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
            editor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await waitFor { draft.text == "😀!" }
        }
    }

    @Test("Code-shaped fields do not substitute quotes, dashes or spelling", arguments: Surface.allCases)
    func literalInput(_ surface: Surface) async throws {
        try await withEditor(surface) { draft, editor, _ in
            #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
            #expect(!editor.isAutomaticDashSubstitutionEnabled)
            #expect(!editor.isAutomaticTextReplacementEnabled)
            #expect(!editor.isAutomaticSpellingCorrectionEnabled)
            for character in ["\"", "a", "\"", " ", "-", "-"] {
                editor.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            try await waitFor { draft.text == "\"a\" --" }
            #expect(editor.string == "\"a\" --")
        }
    }

    @Test("A new document clears only its editor history and resets its caret")
    func documentBoundaryIsolatesUndo() async throws {
        try await withEditor(.json, text: #"{"first":1}"#) { draft, editor, window in
            let editorUndo = try #require(editor.undoManager)
            let windowUndo = try #require(window.undoManager)
            #expect(editorUndo !== windowUndo)
            let otherField = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
            otherField.allowsUndo = true
            window.contentView?.addSubview(otherField)
            #expect(window.makeFirstResponder(otherField))
            #expect(otherField.undoManager === windowUndo)
            otherField.insertText("unrelated", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await waitFor { windowUndo.groupingLevel == 0 }
            #expect(window.makeFirstResponder(editor))

            editor.setSelectedRange(NSRange(location: 11, length: 0))
            editor.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await waitFor { draft.text == #"{"first":1} "# && editorUndo.groupingLevel == 0 }
            #expect(editorUndo.canUndo)

            draft.text = #"{"second":2}"#
            draft.documentID = "second"
            try await waitFor { editor.string == #"{"second":2}"# }
            #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
            #expect(!editorUndo.canUndo)
            #expect(!editorUndo.canRedo)
            #expect(windowUndo.canUndo)
            windowUndo.undo()
            #expect(otherField.string.isEmpty)
            #expect(draft.text == #"{"second":2}"#)
        }
    }

    @Test("Multiline focus follows native navigation and explicit field requests")
    func multilineFocus() async throws {
        try await withEditor(.multiline) { draft, editor, window in
            try await waitFor("Native focus did not reach the field binding") { draft.isFocused }
            let otherField = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
            window.contentView?.addSubview(otherField)
            #expect(window.makeFirstResponder(otherField))
            try await waitFor("Leaving the editor did not clear field focus") { !draft.isFocused }
            draft.isFocused = true
            try await waitFor("The field focus request did not focus the native editor") { window.firstResponder === editor }
            draft.isFocused = false
            try await waitFor("Clearing field focus left the editor focused") { window.firstResponder !== editor }
        }
    }

    @Test("Selection bounds use UTF-16 and never split a composed character")
    func selectionBounds() {
        #expect(DSNativeTextEditingSession.clampedSelections([
            NSRange(location: 1, length: 0), NSRange(location: 1, length: 1),
            NSRange(location: Int.max, length: Int.max),
        ], in: "😀") == [
            NSRange(location: 0, length: 0), NSRange(location: 0, length: 2),
            NSRange(location: 2, length: 0),
        ])
        #expect(DSNativeTextEditingSession.clampedSelections([
            NSRange(location: 1, length: 0),
        ], in: "e\u{0301}") == [NSRange(location: 0, length: 0)])
        #expect(DSNativeTextEditingSession.clampedSelections([], in: "")
                == [NSRange(location: 0, length: 0)])
    }

    @Test("The empty multiline field remains clickable to its bottom after clearing and resizing")
    func multilineViewportFill() async throws {
        try await withEditor(.multiline) { draft, editor, window in
            let scroll = try #require(editor.enclosingScrollView)
            try #require(scroll.contentSize.height > 100)

            func expectBottomTargetsEditor() {
                #expect(editor.frame.height >= scroll.contentSize.height)
                let clip = scroll.contentView
                let bottom = NSPoint(x: clip.bounds.midX,
                                     y: clip.isFlipped ? clip.bounds.maxY - 2 : clip.bounds.minY + 2)
                let point = clip.convert(bottom, to: scroll.superview)
                #expect(scroll.hitTest(point) === editor, "The bottom of the field must target its text editor")
            }

            expectBottomTargetsEditor()
            let longBody = String(repeating: "A line of response body text.\n", count: 40)
            draft.text = longBody
            try await waitFor("Long body text did not grow beyond the viewport") {
                editor.string == longBody && editor.frame.height > scroll.contentSize.height
            }
            draft.text = ""
            try await waitFor("Clearing the body did not reach the native editor") { editor.string.isEmpty }
            expectBottomTargetsEditor()

            window.setContentSize(NSSize(width: 500, height: 440))
            draft.editorHeight = 320
            try await waitFor("The multiline viewport did not grow with the field") { scroll.contentSize.height >= 300 }
            expectBottomTargetsEditor()
        }
    }
}
