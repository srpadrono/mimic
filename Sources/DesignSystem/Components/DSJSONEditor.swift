import SwiftUI
import CodeEditorView
import LanguageSupport

/// JSON editor with syntax highlighting and validation.
/// Wraps CodeEditorView behind a DesignSystem abstraction.
public struct DSJSONEditor: View {
    @Binding private var text: String
    @State private var isValid: Bool = true
    @Environment(\.colorScheme) private var colorScheme
    private let identifier: String
    private let documentID: String?
    private let onValidationChanged: ((Bool) -> Void)?

    /// Update `documentID` together with the hydrated text when changing documents.
    /// Replacements within one document are undoable; a new document starts with empty history.
    public init(
        text: Binding<String>,
        identifier: String,
        documentID: String? = nil,
        onValidationChanged: ((Bool) -> Void)? = nil
    ) {
        self._text = text
        self.identifier = identifier
        self.documentID = documentID
        self.onValidationChanged = onValidationChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSNativeTextEditor(text: $text, documentID: documentID ?? identifier,
                               configurationID: colorScheme, identifier: "ds.jsoneditor.\(identifier)",
                               label: "JSON editor") { session in
                CodeEditor(text: session.textBinding,
                           position: session.positionBinding,
                           messages: session.messagesBinding,
                           language: Self.jsonLanguage)
                    .environment(\.codeEditorLayoutConfiguration,
                                 CodeEditor.LayoutConfiguration(showMinimap: false, wrapText: true))
                    .environment(\.codeEditorTheme, colorScheme == .dark ? Self.darkTheme : Self.lightTheme)
                    .environment(\.colorScheme, colorScheme)
            }
            .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                    .stroke(DSColors.border, lineWidth: DSStroke.hairline)
                    .allowsHitTesting(false)
            )
            .accessibilityIdentifier("ds.jsoneditor.\(identifier)")
            .accessibilityLabel("JSON editor")

            if let error = Self.validationErrorMessage(text: text, isValid: isValid) {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DSColors.destructive)
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

    // MARK: - Metrics

    // Font metrics and both native editor themes share this face.
    static let editorFontName = "SFMono-Regular"
    static let editorFontSize: CGFloat = 13

    /// Height for logical lines. Wrapped lines may need more room; callers provide a minimum height.
    public static func height(forLines lines: Int) -> CGFloat {
        let font = NSFont(name: editorFontName, size: editorFontSize)
            ?? .monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
        let lineHeight = font.ascender - font.descender + font.leading
        return CGFloat(max(1, lines)) * lineHeight.rounded(.up)
    }

    /// Counts logical lines, including CRLF and trailing empty lines, for editor sizing.
    public static func lineCount(of text: String) -> Int {
        text.isEmpty ? 1 : text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    // MARK: - Themes — warm, cohesive with Ink & Electric palette

    // Exposed internally so contrast tests use the surfaces the native editor actually draws.
    static let lightCanvas = DSColors.dominantLightInk.nsColor()
    static let darkCanvas = DSColors.dominantDarkInk.nsColor()

    // Syntax colors and surfaces share DSColors; other native editor roles are explicit here.
    private static let darkTheme = Theme(
        colourScheme: .dark,
        fontName: editorFontName,
        fontSize: editorFontSize,
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

    // The regex grammar colors keys as strings; the read-only formatter distinguishes keys.
    private static let jsonLanguage: LanguageConfiguration = {
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
        fontName: editorFontName,
        fontSize: editorFontSize,
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

    /// Validates whether a string is valid JSON, including top-level scalar values.
    public nonisolated static func validateJSON(_ string: String) -> Bool {
        guard !string.isEmpty else { return true }
        guard let data = string.data(using: .utf8) else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return true
        } catch {
            return false
        }
    }

    /// Re-indents valid JSON without changing key order, string contents or number spelling.
    /// Malformed bodies, scalars and output beyond the shared size budget return nil.
    public nonisolated static func prettyPrint(_ string: String) -> String? {
        guard validateJSON(string) else { return nil }
        return JSONFormatter.prettyPrinted(string, reflow: true)
    }

    static func validationErrorMessage(text: String, isValid: Bool) -> String? {
        guard !text.isEmpty, !isValid else { return nil }
        // Malformed bodies are supported for testing clients' error handling.
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
            try Task.checkCancellation()
            try await sleep(.milliseconds(300))
            try Task.checkCancellation()
            let currentIsValid = await validate(text)
            guard !Task.isCancelled else { return nil }
            onValidationChanged?(currentIsValid)
            return currentIsValid
        } catch {
            return nil
        }
    }

    static func validateAsync(_ string: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        let validation = Task.detached {
            guard !Task.isCancelled else { return false }
            return validateJSON(string)
        }
        return await withTaskCancellationHandler {
            await validation.value
        } onCancel: {
            validation.cancel()
        }
    }
}
