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
                        // The same `inline` rung `DSTextField`'s validation row takes, beside the same
                        // `DSTypography.label`. The two error rows are one idiom and used to be two
                        // literals that happened to agree.
                        .font(.system(size: DSGlyph.inline))
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

    /// The surface each theme fills with, named rather than inlined.
    ///
    /// This is what closes the gap that put the syntax palette's contrast readings on the wrong
    /// background for months: the editor's canvas was a literal inside a twenty-two-argument `Theme`,
    /// so a test could only measure a surface somebody *believed* it had.
    /// `DSContrastTests.syntaxColoursOnTheWellTheyAreDrawnIn` reads these two and requires each to be
    /// the ``DSColors/dominant`` value for its appearance, so the surface the suite measures and the
    /// surface the component sets are the same object rather than two hopes about one.
    static let lightCanvas = DSColors.dominantLightInk.nsColor()
    static let darkCanvas = DSColors.dominantDarkInk.nsColor()

    /// **Seven fields come from `DSColors`; the rest are the editor's own and say so.**
    ///
    /// Both themes used to be twenty-two `NSColor` literals with a comment over three of them claiming
    /// they "mirror `DSColors.Syntax`". A copy is not a mirror, and in light mode the copy had come
    /// adrift: `numberColour` was `(0.63, 0.39, 0.0)` where ``DSColors/Syntax/number`` is
    /// `(0.58, 0.35, 0.0)`, and `keywordColour` `(0.0, 0.40, 0.85)` where
    /// ``DSColors/Syntax/literal`` is `(0.0, 0.38, 0.85)` — both of them the value the token carried
    /// before it was darkened. Nobody had touched the editor when the tokens moved, because nothing
    /// connected them.
    ///
    /// A `Theme` takes `NSColor` per field, which is why `DSColors.Ink` exists: the token and the
    /// theme field are now built from one set of components. The seven are `stringColour`,
    /// `numberColour` and `keywordColour` — the three kinds the grammar below arms with a regex or a
    /// reserved identifier — plus `backgroundColour`, `currentLineColour`, `selectionColour` and
    /// `cursorColour`.
    ///
    /// **`backgroundColour` is ``DSColors/dominant`` — the token whose own comment reads "editor
    /// canvas".** Its light value was already bit-identical to that token; the dark one had drifted to
    /// `(0.137, 0.137, 0.145)`, ΔL\* 3.44 lighter than the canvas it is supposed to be, and light and
    /// dark were derived two different ways as a result. Nothing gets harder to read for the change:
    /// the dark background moves *down*, so every ink on it gains.
    ///
    /// Everything else here — the plain text colour, comments, characters, identifiers, operators,
    /// symbols, types, fields, cases and invisibles — is the editor's own and stays a literal, because
    /// none of them is a role this palette has a name for. That is the only claim being made about
    /// them: whether the JSON grammar can emit the kinds they colour is a question about
    /// `LanguageConfiguration`, a dependency's type, and this comment does not answer it.
    private static let darkTheme = Theme(
        colourScheme: .dark,
        fontName: "SFMono-Regular",
        fontSize: 12,
        textColour: NSColor(srgbRed: 0.87, green: 0.87, blue: 0.89, alpha: 1.0),
        commentColour: NSColor(srgbRed: 0.45, green: 0.48, blue: 0.52, alpha: 1.0),
        stringColour: DSColors.Syntax.stringDarkInk.nsColor(),
        characterColour: NSColor(srgbRed: 0.84, green: 0.79, blue: 0.53, alpha: 1.0),
        numberColour: DSColors.Syntax.numberDarkInk.nsColor(),
        identifierColour: NSColor(srgbRed: 0.38, green: 0.74, blue: 0.66, alpha: 1.0),
        operatorColour: NSColor(srgbRed: 0.60, green: 0.92, blue: 0.85, alpha: 1.0),
        keywordColour: DSColors.Syntax.literalDarkInk.nsColor(),
        symbolColour: NSColor(srgbRed: 0.68, green: 0.68, blue: 0.72, alpha: 1.0),
        typeColour: NSColor(srgbRed: 0.30, green: 0.78, blue: 0.98, alpha: 1.0),
        fieldColour: NSColor(srgbRed: 0.60, green: 0.42, blue: 0.92, alpha: 1.0),
        caseColour: NSColor(srgbRed: 0.78, green: 0.64, blue: 1.0, alpha: 1.0),
        backgroundColour: darkCanvas,
        currentLineColour: DSColors.secondaryDarkInk.nsColor(),
        selectionColour: DSColors.accentInk.nsColor(opacity: 0.25),
        cursorColour: DSColors.accentInk.nsColor(),
        invisiblesColour: NSColor(srgbRed: 0.30, green: 0.33, blue: 0.38, alpha: 1.0)
    )

    /// What the editor treats as JSON.
    ///
    /// Without a `language:` the editor got `LanguageConfiguration.none`, whose every regex is `nil`
    /// — so no token was ever produced and the two twenty-two-field themes on either side of this one
    /// coloured nothing but the plain text. The type doc promised syntax highlighting and the body field rendered a wall of
    /// one colour, while `RequestBodyView` coloured the *same payload* from `DSColors.Syntax`.
    ///
    /// One limitation worth stating: a JSON key and a JSON string are both quoted strings, and a
    /// regex tokenizer cannot tell them apart without lookahead for the colon. So keys take the
    /// string colour here, where `RequestBodyView`'s scanner distinguishes them. Numbers, `true`,
    /// `false` and `null` match the inspector exactly — which this line claimed before it was true.
    /// In light mode the editor's copies of those two hues were the values ``DSColors/Syntax/number``
    /// and ``DSColors/Syntax/literal`` held before they were darkened; both themes read the tokens
    /// themselves now, so "exactly" is the same constant rather than a resemblance.
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

    /// The light half of the pair — see `darkTheme` above for which fields are tokens and why.
    ///
    /// The three syntax fields are where the drift showed, and the readings say why it mattered rather
    /// than only that it was untidy. On this theme's own background, the old `numberColour` measured
    /// **4.60:1** and the old `keywordColour` **5.07**; the tokens they had been copied from read
    /// **5.37** and **5.33**. The number was clearing AA by a tenth in the app's densest reading, on a
    /// value that had already been corrected once somewhere else.
    private static let lightTheme = Theme(
        colourScheme: .light,
        fontName: "SFMono-Regular",
        fontSize: 12,
        textColour: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1.0),
        commentColour: NSColor(srgbRed: 0.45, green: 0.50, blue: 0.55, alpha: 1.0),
        stringColour: DSColors.Syntax.stringLightInk.nsColor(),
        characterColour: NSColor(srgbRed: 0.14, green: 0.19, blue: 0.81, alpha: 1.0),
        numberColour: DSColors.Syntax.numberLightInk.nsColor(),
        identifierColour: NSColor(srgbRed: 0.20, green: 0.48, blue: 0.52, alpha: 1.0),
        operatorColour: NSColor(srgbRed: 0.18, green: 0.05, blue: 0.43, alpha: 1.0),
        keywordColour: DSColors.Syntax.literalLightInk.nsColor(),
        symbolColour: NSColor(srgbRed: 0.24, green: 0.13, blue: 0.48, alpha: 1.0),
        typeColour: NSColor(srgbRed: 0.04, green: 0.29, blue: 0.46, alpha: 1.0),
        fieldColour: NSColor(srgbRed: 0.36, green: 0.15, blue: 0.60, alpha: 1.0),
        caseColour: NSColor(srgbRed: 0.18, green: 0.05, blue: 0.43, alpha: 1.0),
        backgroundColour: lightCanvas,
        currentLineColour: DSColors.secondaryLightInk.nsColor(),
        selectionColour: DSColors.accentInk.nsColor(opacity: 0.18),
        cursorColour: DSColors.accentInk.nsColor(),
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
