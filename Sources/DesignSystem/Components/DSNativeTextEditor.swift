import AppKit
import SwiftUI
import CodeEditorView
import LanguageSupport

/// Keeps external replacements out of the wrapped editor's unregistered string-assignment path.
struct DSNativeTextEditor<Content: View>: NSViewRepresentable {
    @Binding var text: String
    let documentID: String
    let configurationID: AnyHashable
    let identifier: String
    let label: String
    @ViewBuilder let content: (DSNativeTextEditingSession) -> Content
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> DSNativeTextEditingSession {
        DSNativeTextEditingSession(text: $text, documentID: documentID)
    }

    func makeNSView(context: Context) -> Host {
        Host(session: context.coordinator, configurationID: configurationID,
             identifier: identifier, label: label, rootView: content(context.coordinator))
    }

    func updateNSView(_ host: Host, context: Context) {
        context.coordinator.attach(in: host.editor)
        context.coordinator.update(text: $text, documentID: documentID, isEnabled: isEnabled)
        if host.configurationID != configurationID {
            host.configurationID = configurationID
            host.editor.rootView = content(context.coordinator)
        }
    }

    static func dismantleNSView(_ host: Host, coordinator: DSNativeTextEditingSession) {
        coordinator.detach()
    }

    final class Host: NSView {
        let editor: NSHostingView<Content>
        let session: DSNativeTextEditingSession
        var configurationID: AnyHashable

        init(session: DSNativeTextEditingSession, configurationID: AnyHashable,
             identifier: String, label: String, rootView: Content) {
            self.session = session
            self.configurationID = configurationID
            self.editor = NSHostingView(rootView: rootView)
            super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            editor.sizingOptions = []
            editor.frame = bounds
            editor.autoresizingMask = [.width, .height]
            addSubview(editor)
            session.identifier = identifier
            session.label = label
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            editor.layoutSubtreeIfNeeded()
            session.attach(in: editor)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            session.attach(in: editor)
        }
    }
}

/// A plain AppKit editor has one binding/undo owner, unlike wrapping SwiftUI's TextEditor.
struct DSPlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let identifier: String
    let label: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> DSNativeTextEditingSession {
        DSNativeTextEditingSession(text: $text, documentID: identifier)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ViewportScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let editor = TextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        // Matches DSTypography.code and the JSON editor's native font metrics.
        editor.font = NSFont.monospacedSystemFont(ofSize: DSJSONEditor.editorFontSize, weight: .regular)
        editor.textColor = NSColor(DSColors.labelPrimary)
        editor.insertionPointColor = NSColor(DSColors.accent)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor

        let session = context.coordinator
        session.identifier = identifier
        session.label = label
        session.attach(in: scroll)
        editor.updateFocus($isFocused)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(text: $text, documentID: identifier, isEnabled: isEnabled)
        (scroll.documentView as? TextView)?.updateFocus($isFocused)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: DSNativeTextEditingSession) {
        (scroll.documentView as? TextView)?.focusBinding = nil
        coordinator.detach()
    }

    final class ViewportScrollView: NSScrollView {
        override func layout() {
            super.layout()
            guard let editor = documentView as? NSTextView else { return }
            let minimumHeight = contentSize.height
            if editor.minSize.height != minimumHeight {
                editor.minSize = NSSize(width: editor.minSize.width, height: minimumHeight)
            }
            if editor.frame.height < minimumHeight {
                editor.setFrameSize(NSSize(width: editor.frame.width, height: minimumHeight))
            }
        }
    }

    final class TextView: NSTextView {
        var focusBinding: Binding<Bool>?
        private var requestedFocus: Bool?

        func updateFocus(_ binding: Binding<Bool>) {
            focusBinding = binding
            guard requestedFocus != binding.wrappedValue else { return }
            requestedFocus = binding.wrappedValue
            applyFocusRequest()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyFocusRequest()
        }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { publishFocus() }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { publishFocus() }
            return accepted
        }

        private func applyFocusRequest() {
            guard let window, let requestedFocus else { return }
            if requestedFocus, isEditable, window.firstResponder !== self {
                window.makeFirstResponder(self)
            } else if !requestedFocus, window.firstResponder === self {
                window.makeFirstResponder(nil)
            }
        }

        private func publishFocus() {
            // A programmatic focus request can arrive during updateNSView. Publish after it ends.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, let binding = self.focusBinding else { return }
                let focused = window.firstResponder === self
                binding.wrappedValue = focused
            }
        }
    }
}

/// Bindings here intentionally do not invalidate the inner hosting view on every keystroke.
/// CodeEditorView otherwise breaks native typing coalescing on every SwiftUI update.
@MainActor
final class DSNativeTextEditingSession {
    private var binding: Binding<String>
    private var text: String
    private var documentID: String
    private var position = CodeEditor.Position()
    private var messages: Set<TextLocated<Message>> = []
    private var applyingExternalChange = false
    private var isEnabled = true
    private weak var textView: NSTextView?
    private var delegate: Delegate?
    let undoManager = UndoManager()
    var identifier = ""
    var label = ""

    init(text: Binding<String>, documentID: String) {
        self.binding = text
        self.text = text.wrappedValue
        self.documentID = documentID
    }

    var textBinding: Binding<String> {
        Binding(get: { [weak self] in self?.text ?? "" },
                set: { [weak self] in self?.nativeTextChanged($0) })
    }

    var positionBinding: Binding<CodeEditor.Position> {
        Binding(get: { [weak self] in self?.position ?? .init() },
                set: { [weak self] in self?.position = $0 })
    }

    var messagesBinding: Binding<Set<TextLocated<Message>>> {
        Binding(get: { [weak self] in self?.messages ?? [] },
                set: { [weak self] in self?.messages = $0 })
    }

    func update(text binding: Binding<String>, documentID: String, isEnabled: Bool) {
        let incoming = binding.wrappedValue
        let changedDocument = self.documentID != documentID
        self.binding = binding
        self.documentID = documentID
        self.isEnabled = isEnabled
        textView?.isEditable = isEnabled

        if changedDocument {
            text = incoming
            position = .init()
            undoManager.removeAllActions()
            if let textView { replace(in: textView, with: incoming, resettingDocument: true) }
        } else if incoming != text {
            text = incoming
            if let textView { replace(in: textView, with: incoming, resettingDocument: false) }
        }
    }

    func attach(in root: NSView) {
        guard let candidate = textView ?? Self.documentTextView(in: root) else { return }
        if textView !== candidate {
            textView = candidate
            delegate = Delegate(session: self, forwardingTo: candidate.delegate)
            candidate.delegate = delegate
            candidate.allowsUndo = true
            candidate.isAutomaticQuoteSubstitutionEnabled = false
            candidate.isAutomaticDashSubstitutionEnabled = false
            candidate.isAutomaticTextReplacementEnabled = false
            candidate.isAutomaticSpellingCorrectionEnabled = false
            candidate.isContinuousSpellCheckingEnabled = false
            candidate.setAccessibilityIdentifier(identifier)
            candidate.setAccessibilityLabel(label)
            replace(in: candidate, with: text, resettingDocument: true)
        } else if let delegate, candidate.delegate !== delegate {
            delegate.forwardedDelegate = candidate.delegate
            candidate.delegate = delegate
        }
        candidate.isEditable = isEnabled
    }

    func detach() {
        textView?.breakUndoCoalescing()
        undoManager.removeAllActions()
        delegate?.stopObservingUndo()
        if let textView, let delegate, textView.delegate === delegate {
            textView.delegate = delegate.forwardedDelegate
        }
        textView = nil
        delegate = nil
    }

    /// Only searches the view owned by this representable, without private package class names.
    static func documentTextView(in root: NSView) -> NSTextView? {
        if let scroll = root as? NSScrollView,
           let textView = scroll.documentView as? NSTextView, textView.isEditable {
            return textView
        }
        for child in root.subviews {
            if let textView = documentTextView(in: child) { return textView }
        }
        return nil
    }

    private func nativeTextChanged(_ value: String) {
        text = value
        guard !applyingExternalChange, binding.wrappedValue != value else { return }
        binding.wrappedValue = value
    }

    private func replace(in textView: NSTextView, with value: String, resettingDocument: Bool) {
        textView.breakUndoCoalescing()

        if resettingDocument {
            applyingExternalChange = true
            undoManager.disableUndoRegistration()
            if textView.string != value {
                textView.string = value
                textView.didChangeText()
            }
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            if let scroll = textView.enclosingScrollView {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            undoManager.enableUndoRegistration()
            undoManager.removeAllActions()
            applyingExternalChange = false
        } else if textView.string != value {
            let previous = Snapshot(textView)
            let replacement = Snapshot(text: value, selections: previous.selections)
            undoManager.beginUndoGrouping()
            if apply(replacement, to: textView) {
                registerUndo(restoring: previous)
                undoManager.setActionName("Replace text")
            }
            undoManager.endUndoGrouping()
        }

        position.selections = textView.selectedRanges.map(\.rangeValue)
        textView.breakUndoCoalescing()
        textView.needsDisplay = true
    }

    private struct Snapshot {
        let text: String
        let selections: [NSRange]

        init(text: String, selections: [NSRange]) {
            self.text = text
            self.selections = selections
        }

        init(_ textView: NSTextView) {
            self.init(text: textView.string, selections: textView.selectedRanges.map(\.rangeValue))
        }
    }

    /// Native text undo restores its insertion point, not an arbitrary selection before Format.
    /// One snapshot action preserves both while leaving earlier typing actions on the native stack.
    private func registerUndo(restoring snapshot: Snapshot) {
        undoManager.registerUndo(withTarget: self) { session in
            guard let textView = session.textView else { return }
            let inverse = Snapshot(textView)
            textView.breakUndoCoalescing()
            if session.apply(snapshot, to: textView) {
                session.registerUndo(restoring: inverse)
                session.nativeTextChanged(textView.string)
            }
            textView.breakUndoCoalescing()
        }
    }

    private func apply(_ snapshot: Snapshot, to textView: NSTextView) -> Bool {
        applyingExternalChange = true
        undoManager.disableUndoRegistration()
        defer {
            undoManager.enableUndoRegistration()
            applyingExternalChange = false
        }
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        let selections = Self.clampedSelections(snapshot.selections, in: snapshot.text)
        let previousPosition = position
        position.selections = selections
        guard textView.shouldChangeText(in: range, replacementString: snapshot.text) else {
            position = previousPosition
            return false
        }
        textView.textStorage?.replaceCharacters(in: range, with: snapshot.text)
        textView.selectedRanges = selections.map { NSValue(range: $0) }
        textView.didChangeText()
        text = textView.string
        position.selections = textView.selectedRanges.map(\.rangeValue)
        textView.needsDisplay = true
        return true
    }

    static func clampedSelections(_ ranges: [NSRange], in text: String) -> [NSRange] {
        let string = text as NSString
        let length = string.length
        return (ranges.isEmpty ? [NSRange(location: 0, length: 0)] : ranges).map { range in
            let start = min(max(0, range.location), length)
            let count = min(max(0, range.length), length - start)
            if count > 0 {
                return string.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: count))
            }
            let caret = start < length ? string.rangeOfComposedCharacterSequence(at: start).location : length
            return NSRange(location: caret, length: 0)
        }
    }

    private nonisolated final class Delegate: NSObject, NSTextViewDelegate {
        @MainActor private weak var session: DSNativeTextEditingSession?
        private weak var target: (any NSTextViewDelegate)?

        @MainActor var forwardedDelegate: (any NSTextViewDelegate)? {
            get { target }
            set { target = newValue }
        }

        @MainActor
        init(session: DSNativeTextEditingSession, forwardingTo delegate: (any NSTextViewDelegate)?) {
            self.session = session
            self.target = delegate
            super.init()
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoGroupDidFinish(_:)),
                                                       name: name, object: session.undoManager)
            }
        }

        @MainActor
        func stopObservingUndo() {
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.removeObserver(self, name: name, object: session?.undoManager)
            }
        }

        @MainActor @objc
        func undoGroupDidFinish(_ notification: Notification) {
            // Native undo can replay text storage without a textDidChange delegate callback.
            // Observe only our manager, after its whole group has finished replaying.
            guard let session, let view = session.textView else { return }
            session.nativeTextChanged(view.string)
        }

        @MainActor
        func undoManager(for view: NSTextView) -> UndoManager? { session?.undoManager }

        @MainActor
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { session?.nativeTextChanged(view.string) }
            forwardedDelegate?.textDidChange?(notification)
        }

        override func responds(to selector: Selector!) -> Bool {
            // AppKit calls these NSObject hooks synchronously while using its main-actor delegate.
            MainActor.preconditionIsolated()
            return super.responds(to: selector) || target?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            MainActor.preconditionIsolated()
            if target?.responds(to: selector) == true { return target }
            return super.forwardingTarget(for: selector)
        }
    }
}
