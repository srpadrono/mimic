import DesignSystem
import SwiftUI

/// A typeable status code in one field, as the endpoint editor and the journey step sheet show it:
/// the status dot, the code in SF Mono and the status colour, its reason phrase, and a menu of
/// common codes at the trailing edge.
///
/// The field only edits `text`. What counts as a code is the caller's to say through `code`, which
/// colours the dot and the digits and names the reason phrase; `nil` draws them neutral.
public struct StatusCodeField: View {
    /// Where the field sits, which sets its height and its menu's glyph.
    public enum Size {
        /// 24 pt, in a panel row, with a down chevron: the endpoint editor.
        case panel
        /// 28 pt, in a sheet's form, with an up-and-down chevron: the journey step sheet.
        case sheet
    }

    @Binding private var text: String
    private let code: Int?
    private let size: Size
    private let isInvalid: Bool
    private var isFocused: FocusState<Bool>.Binding
    private let fieldIdentifier: String
    private let menuIdentifier: String
    private let reasonIdentifier: String?
    private let onCommit: () -> Void

    /// `onCommit` runs when the code is submitted with Return or picked from the menu.
    public init(
        text: Binding<String>,
        code: Int?,
        size: Size,
        isInvalid: Bool,
        isFocused: FocusState<Bool>.Binding,
        fieldIdentifier: String,
        menuIdentifier: String,
        reasonIdentifier: String? = nil,
        onCommit: @escaping () -> Void = {}
    ) {
        _text = text
        self.code = code
        self.size = size
        self.isInvalid = isInvalid
        self.isFocused = isFocused
        self.fieldIdentifier = fieldIdentifier
        self.menuIdentifier = menuIdentifier
        self.reasonIdentifier = reasonIdentifier
        self.onCommit = onCommit
    }

    /// The codes the menu offers; any other is typed.
    public static let commonCodes = [200, 201, 202, 204, 301, 302, 304, 400, 401, 403, 404, 409, 422, 429,
                                     500, 502, 503, 504]

    /// Three SF Mono 12 medium digits (21.7pt) and a point for the caret, so the reason phrase
    /// starts in one place, 6pt after the code as the boards draw it, and "Service Unavailable"
    /// fits the editor's 196pt field.
    private static let codeWidth: CGFloat = 23

    public var body: some View {
        HStack(spacing: DSSpacing.xs + DSSpacing.xxs) {
            DSStatusDot(code.map { DSColors.httpStatusColor(for: $0) } ?? DSColors.labelTertiary)
            TextField("200", text: $text)
                .textFieldStyle(.plain)
                .font(DSTypography.status)
                .foregroundStyle(code.map { DSColors.httpStatusColor(for: $0) } ?? DSColors.labelPrimary)
                .frame(width: Self.codeWidth)
                .focused(isFocused)
                .accessibilityIdentifier(fieldIdentifier)
                .accessibilityLabel("Status code")
                .onSubmit(onCommit)
            reason
            Spacer(minLength: 0)
            menu
        }
        .dsFieldChrome(height: height, cornerRadius: cornerRadius, isFocused: isFocused.wrappedValue,
                       isInvalid: isInvalid, horizontalPadding: horizontalPadding)
    }

    @ViewBuilder
    private var reason: some View {
        if let code {
            let phrase = Text(HTTPStatusText.reasonPhrase(for: code))
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let reasonIdentifier {
                phrase.accessibilityIdentifier(reasonIdentifier)
            } else {
                // The code already says it; the phrase would only be read twice.
                phrase.accessibilityHidden(true)
            }
        }
    }

    private var menu: some View {
        Menu {
            ForEach(Self.commonCodes, id: \.self) { option in
                Button("\(option) \(HTTPStatusText.reasonPhrase(for: option))") {
                    text = String(option)
                    onCommit()
                }
            }
        } label: {
            // The boards' 10pt chevron box, 6pt after the reason phrase.
            DSDisclosureChevron(size == .panel ? .down : .upDown)
                .frame(width: DSGlyph.disclosure, height: height)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a common status code")
        .accessibilityIdentifier(menuIdentifier)
        .accessibilityLabel("Common status codes")
    }

    private var height: CGFloat {
        size == .panel ? DSControlHeight.regular : DSControlHeight.large
    }

    private var cornerRadius: CGFloat {
        size == .panel ? DSCornerRadius.field : DSCornerRadius.segment
    }

    private var horizontalPadding: CGFloat {
        size == .panel ? DSSpacing.sm : 10
    }
}
