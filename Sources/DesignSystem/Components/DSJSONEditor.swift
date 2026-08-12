import SwiftUI
import CodeEditorView
import LanguageSupport

/// JSON editor with syntax highlighting and validation.
/// Wraps CodeEditorView behind a DesignSystem abstraction.
public struct DSJSONEditor: View {
    @Binding private var text: String
    @State private var position = CodeEditor.Position()
    @State private var messages: Set<TextLocated<Message>> = []
    @State private var isValid: Bool = true
    @Environment(\.colorScheme) private var colorScheme
    private let identifier: String
    private let onValidationChanged: ((Bool) -> Void)?

    public init(
        text: Binding<String>,
        identifier: String,
        onValidationChanged: ((Bool) -> Void)? = nil
    ) {
        self._text = text
        self.identifier = identifier
        self.onValidationChanged = onValidationChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CodeEditor(
                text: $text,
                position: $position,
                messages: $messages,
                language: Self.jsonLanguage
            )
            // Through the environment, not the initializer: the `layout:` parameter is deprecated,
            // and passing it kept a warning in every Release build.
            //
            // `.standard` turns the minimap on, and a minimap is for navigating a thousand-line
            // source file. A mock response body is a few dozen lines at most, so it rendered as an
            // unexplained grey block floating at the top-right of the field — which reads as a
            // drawing artefact, not a feature. Xcode has one for the same reason it has a scroll
            // bar: there is somewhere to scroll to.
            //
            // `wrapText` stays on. A minified payload is one very long line, and the alternative is
            // scrolling sideways to read it — the exact failure the request inspector's body view
            // was rebuilt to remove.
            .environment(
                \.codeEditorLayoutConfiguration,
                CodeEditor.LayoutConfiguration(showMinimap: false, wrapText: true)
            )
            .environment(\.codeEditorTheme, colorScheme == .dark ? Self.darkTheme : Self.lightTheme)
            .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                    .stroke(DSColors.border, lineWidth: DSStroke.hairline)
            )
            .accessibilityIdentifier("ds.jsoneditor.\(identifier)")

            if let error = Self.validationErrorMessage(text: text, isValid: isValid) {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DSColors.destructive)
                        .font(.system(size: 10))
                    Text(error)
                        .font(DSTypography.label)
                        .foregroundStyle(DSColors.destructive)
                }
                .padding(.top, DSSpacing.xs)
                .accessibilityIdentifier("ds.jsoneditor.\(identifier).error")
            }
        }
        .task(id: text) {
            if let currentIsValid = await Self.resolvedValidationResult(
                for: text,
                onValidationChanged: onValidationChanged
            ) {
                self.isValid = currentIsValid
            }
        }
    }

    // MARK: - Themes — warm, cohesive with Ink & Electric palette

    private static let darkTheme = Theme(
        colourScheme: .dark,
        fontName: "SFMono-Regular",
        fontSize: 12,
        textColour: NSColor(srgbRed: 0.87, green: 0.87, blue: 0.89, alpha: 1.0),
        commentColour: NSColor(srgbRed: 0.45, green: 0.48, blue: 0.52, alpha: 1.0),
        // These three mirror `DSColors.Syntax` so the editor and the request inspector colour the
        // same payload the same way. They were a stock editor theme that matched nothing else.
        stringColour: NSColor(srgbRed: 0.259, green: 0.784, blue: 0.757, alpha: 1.0),
        characterColour: NSColor(srgbRed: 0.84, green: 0.79, blue: 0.53, alpha: 1.0),
        numberColour: NSColor(srgbRed: 1.0, green: 0.694, blue: 0.306, alpha: 1.0),
        identifierColour: NSColor(srgbRed: 0.38, green: 0.74, blue: 0.66, alpha: 1.0),
        operatorColour: NSColor(srgbRed: 0.60, green: 0.92, blue: 0.85, alpha: 1.0),
        keywordColour: NSColor(srgbRed: 0.316, green: 0.657, blue: 1.0, alpha: 1.0),
        symbolColour: NSColor(srgbRed: 0.68, green: 0.68, blue: 0.72, alpha: 1.0),
        typeColour: NSColor(srgbRed: 0.30, green: 0.78, blue: 0.98, alpha: 1.0),
        fieldColour: NSColor(srgbRed: 0.60, green: 0.42, blue: 0.92, alpha: 1.0),
        caseColour: NSColor(srgbRed: 0.78, green: 0.64, blue: 1.0, alpha: 1.0),
        backgroundColour: NSColor(srgbRed: 0.137, green: 0.137, blue: 0.145, alpha: 1.0),
        currentLineColour: NSColor(srgbRed: 0.173, green: 0.173, blue: 0.180, alpha: 1.0),
        selectionColour: NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 0.25),
        cursorColour: NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1.0),
        invisiblesColour: NSColor(srgbRed: 0.30, green: 0.33, blue: 0.38, alpha: 1.0)
    )

    /// What the editor treats as JSON.
    ///
    /// Without a `language:` the editor got `LanguageConfiguration.none`, whose every regex is `nil`
    /// — so no token was ever produced and the two 22-line themes below coloured nothing but the
    /// plain text. The type doc promised syntax highlighting and the body field rendered a wall of
    /// one colour, while `RequestBodyView` coloured the *same payload* from `DSColors.Syntax`.
    ///
    /// One limitation worth stating: a JSON key and a JSON string are both quoted strings, and a
    /// regex tokenizer cannot tell them apart without lookahead for the colon. So keys take the
    /// string colour here, where `RequestBodyView`'s scanner distinguishes them. Numbers, `true`,
    /// `false` and `null` match the inspector exactly.
    /// Built from `Regex` values rather than pattern strings: the string-taking initializer is
    /// deprecated, and swapping one deprecation for another is not a fix.
    private static let jsonLanguage: LanguageConfiguration = {
        // `try?` because these are literals, not input. A nil would mean the pattern beside it is
        // malformed — a programming error whose only symptom is that highlighting stops, which the
        // next look at the body field shows immediately. Propagating it through a static would buy
        // nothing a caller could act on.
        let string = try? Regex<Substring>(#""(?:[^"\\]|\\.)*""#, as: Substring.self)
        let number = try? Regex<Substring>(
            #"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"#,
            as: Substring.self
        )

        return LanguageConfiguration(
            name: "JSON",
            supportsSquareBrackets: true,
            supportsCurlyBrackets: true,
            stringRegex: string,
            characterRegex: nil,
            numberRegex: number,
            singleLineComment: nil,
            nestedComment: nil,
            identifierRegex: nil,
            operatorRegex: nil,
            reservedIdentifiers: ["true", "false", "null"],
            reservedOperators: []
        )
    }()

    private static let lightTheme = Theme(
        colourScheme: .light,
        fontName: "SFMono-Regular",
        fontSize: 12,
        textColour: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1.0),
        commentColour: NSColor(srgbRed: 0.45, green: 0.50, blue: 0.55, alpha: 1.0),
        // Mirrors `DSColors.Syntax`, same reason as the dark theme above.
        stringColour: NSColor(srgbRed: 0.0, green: 0.44, blue: 0.42, alpha: 1.0),
        characterColour: NSColor(srgbRed: 0.14, green: 0.19, blue: 0.81, alpha: 1.0),
        numberColour: NSColor(srgbRed: 0.63, green: 0.39, blue: 0.0, alpha: 1.0),
        identifierColour: NSColor(srgbRed: 0.20, green: 0.48, blue: 0.52, alpha: 1.0),
        operatorColour: NSColor(srgbRed: 0.18, green: 0.05, blue: 0.43, alpha: 1.0),
        keywordColour: NSColor(srgbRed: 0.0, green: 0.40, blue: 0.85, alpha: 1.0),
        symbolColour: NSColor(srgbRed: 0.24, green: 0.13, blue: 0.48, alpha: 1.0),
        typeColour: NSColor(srgbRed: 0.04, green: 0.29, blue: 0.46, alpha: 1.0),
        fieldColour: NSColor(srgbRed: 0.36, green: 0.15, blue: 0.60, alpha: 1.0),
        caseColour: NSColor(srgbRed: 0.18, green: 0.05, blue: 0.43, alpha: 1.0),
        backgroundColour: NSColor(srgbRed: 0.973, green: 0.973, blue: 0.980, alpha: 1.0),
        currentLineColour: NSColor(srgbRed: 0.941, green: 0.945, blue: 0.965, alpha: 1.0),
        selectionColour: NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 0.18),
        cursorColour: NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1.0),
        invisiblesColour: NSColor(srgbRed: 0.84, green: 0.84, blue: 0.86, alpha: 1.0)
    )

    // MARK: - JSON Utilities

    /// Validates whether a string is valid JSON.
    public nonisolated static func validateJSON(_ string: String) -> Bool {
        guard !string.isEmpty else { return true }
        guard let data = string.data(using: .utf8) else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return true
        } catch {
            return false
        }
    }

    /// Re-indents a body without touching its key order.
    ///
    /// This used to be `JSONSerialization` in, `[.prettyPrinted, .sortedKeys]` out — and that is a
    /// data-loss bug, not a formatting choice. A round trip through a dictionary drops the payload's
    /// key order, and `.sortedKeys` then alphabetises it. This is the *editor's* Format button, so
    /// the reordered text was written straight back into the saved response body: a mock arranged to
    /// mirror the real API's payload came back rearranged, and the served response changed with it.
    ///
    /// It delegates to `JSONFormatter` — the character scanner already written for the traffic log,
    /// and already covered by a `preservesKeyOrder` test — so the editor and the inspector cannot
    /// format the same body two different ways.
    public nonisolated static func prettyPrint(_ string: String) -> String? {
        // `reflow: true` — pressing Format is an instruction, not a hint. Without it the scanner's
        // "do not fight a layout somebody chose" rule applied here too, so the button was enabled,
        // clickable and did nothing for any body already spread across lines.
        JSONFormatter.prettyPrinted(string, reflow: true)
    }

    static func validationErrorMessage(text: String, isValid: Bool) -> String? {
        guard !text.isEmpty, !isValid else { return nil }
        // Says what actually happens. It used to promise "Fix the syntax to save", and the body
        // was committed regardless — a message that is simply false about the app it is in.
        //
        // Saving it is the right behaviour, though, which is why the message moved rather than the
        // save: a mock server whose whole job is standing in for a backend has to be able to serve
        // a malformed payload on purpose. Testing what your client does with broken JSON is the
        // same kind of task as testing what it does with a dropped connection, and Mimic already
        // simulates that. So this is a warning, not a refusal.
        return "Not valid JSON \u{2014} it is still saved and served exactly as written."
    }

    @MainActor
    static func resolvedValidationResult(
        for text: String,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        validate: @Sendable (String) async -> Bool = validateAsync,
        onValidationChanged: ((Bool) -> Void)? = nil
    ) async -> Bool? {
        do {
            try await sleep(.milliseconds(300))
            let currentIsValid = await validate(text)
            guard !Task.isCancelled else { return nil }
            onValidationChanged?(currentIsValid)
            return currentIsValid
        } catch {
            return nil
        }
    }

    static func validateAsync(_ string: String) async -> Bool {
        await Task.detached {
            validateJSON(string)
        }.value
    }
}
