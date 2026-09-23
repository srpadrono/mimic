import SwiftUI

/// A labelled multiline input for headers, bodies and other code-shaped text in settings sheets.
public struct DSMultilineField: View {
    private let title: String
    @Binding private var text: String
    private let height: CGFloat
    private let identifier: String
    private let accessory: AnyView?
    @FocusState private var isFocused: Bool

    public init(_ title: String, text: Binding<String>, height: CGFloat, identifier: String) {
        self.title = title
        self._text = text
        self.height = height
        self.identifier = identifier
        self.accessory = nil
    }

    /// An action beside the field label, sharing its header row rather than floating over the editor.
    public init<Accessory: View>(_ title: String, text: Binding<String>, height: CGFloat,
                                 identifier: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self._text = text
        self.height = height
        self.identifier = identifier
        self.accessory = AnyView(accessory())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.xs) {
                Text(title)
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                if let accessory {
                    Spacer(minLength: DSSpacing.xs)
                    accessory
                }
            }

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
