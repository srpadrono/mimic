import SwiftUI

/// A labelled multiline input for headers, bodies and other code-shaped text in settings sheets.
public struct DSMultilineField: View {
    private let title: String
    @Binding private var text: String
    private let height: CGFloat
    private let identifier: String
    private let accessory: AnyView?
    private let externalFocus: Binding<Bool>?
    @State private var hasFocus = false

    public init(_ title: String, text: Binding<String>, height: CGFloat, identifier: String,
                isFocused: Binding<Bool>? = nil) {
        self.title = title
        self._text = text
        self.height = height
        self.identifier = identifier
        self.accessory = nil
        self.externalFocus = isFocused
    }

    /// An action beside the field label, sharing its header row rather than floating over the editor.
    public init<Accessory: View>(_ title: String, text: Binding<String>, height: CGFloat,
                                 identifier: String, isFocused: Binding<Bool>? = nil,
                                 @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self._text = text
        self.height = height
        self.identifier = identifier
        self.accessory = AnyView(accessory())
        self.externalFocus = isFocused
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

            DSPlainTextEditor(text: $text, isFocused: focusBinding, identifier: identifier, label: title)
                .padding(DSSpacing.xs)
                .frame(height: height)
                .background(DSColors.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                        .stroke(hasFocus ? DSColors.borderFocused : DSColors.border,
                                lineWidth: hasFocus ? DSStroke.focusRing : DSStroke.hairline)
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(title)
        }
    }

    private var focusBinding: Binding<Bool> {
        Binding(get: { externalFocus?.wrappedValue ?? hasFocus }, set: { focused in
            hasFocus = focused
            if let externalFocus, externalFocus.wrappedValue != focused { externalFocus.wrappedValue = focused }
        })
    }
}
