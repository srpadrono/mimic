import SwiftUI

/// A labelled multiline input for headers, bodies and other code-shaped text in settings sheets.
public struct DSMultilineField: View {
    private let title: String
    @Binding private var text: String
    private let height: CGFloat
    private let identifier: String
    @FocusState private var isFocused: Bool

    public init(_ title: String, text: Binding<String>, height: CGFloat, identifier: String) {
        self.title = title
        self._text = text
        self.height = height
        self.identifier = identifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(title)
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelSecondary)

            TextEditor(text: $text)
                .font(DSTypography.code)
                .scrollContentBackground(.hidden)
                .padding(DSSpacing.xs)
                .frame(height: height)
                .focused($isFocused)
                .background(DSColors.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                        .stroke(isFocused ? DSColors.borderFocused : DSColors.border,
                                lineWidth: isFocused ? DSStroke.focusRing : DSStroke.hairline)
                }
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(title)
        }
    }
}
