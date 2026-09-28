import SwiftUI

/// A labelled multiline input for headers, bodies and other code-shaped text: a code well with a
/// hairline, and an accent border with a halo while focused.
public struct DSMultilineField: View {
    private let title: String
    @Binding private var text: String
    private let height: CGFloat
    private let identifier: String
    private let labelPlacement: DSTextField.LabelPlacement
    private let accessory: AnyView?
    private let externalFocus: Binding<Bool>?
    @State private var hasFocus = false

    public init(_ title: String, text: Binding<String>, height: CGFloat, identifier: String,
                isFocused: Binding<Bool>? = nil, labelPlacement: DSTextField.LabelPlacement = .top) {
        self.title = title
        self._text = text
        self.height = height
        self.identifier = identifier
        self.labelPlacement = labelPlacement
        self.accessory = nil
        self.externalFocus = isFocused
    }

    /// An action beside the field label, sharing its header row rather than floating over the editor.
    public init<Accessory: View>(_ title: String, text: Binding<String>, height: CGFloat,
                                 identifier: String, isFocused: Binding<Bool>? = nil,
                                 labelPlacement: DSTextField.LabelPlacement = .top,
                                 @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self._text = text
        self.height = height
        self.identifier = identifier
        self.labelPlacement = labelPlacement
        self.accessory = AnyView(accessory())
        self.externalFocus = isFocused
    }

    public var body: some View {
        switch labelPlacement {
        case .top:
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                HStack(spacing: DSSpacing.xs) {
                    Text(title)
                        .font(DSTypography.callout)
                        .foregroundStyle(DSColors.labelSecondary)
                        .accessibilityHidden(true)
                    if let accessory {
                        Spacer(minLength: DSSpacing.xs)
                        accessory
                    }
                }
                well
            }
        case .leading:
            DSFormRow(title, alignment: .top) {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    if let accessory {
                        HStack(spacing: DSSpacing.xs) {
                            Spacer(minLength: 0)
                            accessory
                        }
                    }
                    well
                }
            }
        case .hidden:
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                if let accessory {
                    HStack(spacing: DSSpacing.xs) {
                        Spacer(minLength: 0)
                        accessory
                    }
                }
                well
            }
        }
    }

    private var well: some View {
        DSPlainTextEditor(text: $text, isFocused: focusBinding, identifier: identifier, label: title)
            .padding(.vertical, DSSpacing.sm)
            .padding(.horizontal, DSSpacing.sm)
            .frame(height: height)
            .background(DSColors.code)
            .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: DSCornerRadius.card)
                    .strokeBorder(hasFocus ? DSColors.accent : DSColors.fieldBorder,
                                  lineWidth: hasFocus ? DSStroke.emphasis : DSStroke.hairline)
                    .allowsHitTesting(false)
            }
            .overlay {
                if hasFocus {
                    RoundedRectangle(cornerRadius: DSCornerRadius.card + DSStroke.focusHalo / 2)
                        .stroke(DSColors.focusRing, lineWidth: DSStroke.focusHalo)
                        .padding(-DSStroke.focusHalo / 2)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: DSAnimation.fast), value: hasFocus)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(title)
    }

    private var focusBinding: Binding<Bool> {
        Binding(get: { externalFocus?.wrappedValue ?? hasFocus }, set: { focused in
            hasFocus = focused
            if let externalFocus, externalFocus.wrappedValue != focused { externalFocus.wrappedValue = focused }
        })
    }
}
