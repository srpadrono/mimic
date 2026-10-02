import SwiftUI

/// A labelled text field. The label sits in a right-aligned column beside the field, as in every
/// sheet; units such as "ms" sit inside the field.
public struct DSTextField: View {
    public enum LabelPlacement {
        /// A right-aligned column to the left: sheets.
        case leading
        /// Above the field: narrow panes.
        case top
        /// No visible label; the label is only announced.
        case hidden
    }

    private let label: String
    @Binding private var text: String
    private let placeholder: String
    private let validation: String?
    private let validationIdentifier: String?
    private let controlWidth: CGFloat?
    private let inputIdentifier: String?
    private let identifier: String
    private let unit: String?
    private let monospaced: Bool
    private let labelPlacement: LabelPlacement
    private let height: CGFloat
    @FocusState private var isFocused: Bool

    public init(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        validation: String? = nil,
        validationIdentifier: String? = nil,
        controlWidth: CGFloat? = nil,
        inputIdentifier: String? = nil,
        unit: String? = nil,
        monospaced: Bool = false,
        labelPlacement: LabelPlacement = .leading,
        height: CGFloat = DSControlHeight.large,
        identifier: String
    ) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.validation = validation
        self.validationIdentifier = validationIdentifier
        self.controlWidth = controlWidth
        self.inputIdentifier = inputIdentifier
        self.unit = unit
        self.monospaced = monospaced
        self.labelPlacement = labelPlacement
        self.height = height
        self.identifier = identifier
    }

    public var body: some View {
        switch labelPlacement {
        case .leading:
            DSFormRow(label, alignment: .top, controlHeight: height) { fieldStack }
        case .top:
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(label)
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .accessibilityIdentifier("ds.textfield.\(identifier).label")
                fieldStack
            }
        case .hidden:
            fieldStack
        }
    }

    /// Code in a sheet's 28pt field is 13pt; in a 24pt field inside a settings row it is 12pt.
    private var textFont: Font {
        guard monospaced else { return DSTypography.body }
        return height >= DSControlHeight.large ? DSTypography.codeLarge : DSTypography.code
    }

    private var fieldStack: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: DSSpacing.xs) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(textFont)
                    .focused($isFocused)
                    .accessibilityIdentifier(inputIdentifier ?? "ds.textfield.\(identifier)")
                    .accessibilityLabel(label)
                if let unit {
                    Text(unit)
                        .font(DSTypography.callout)
                        .foregroundStyle(DSColors.labelTertiary)
                        .accessibilityHidden(true)
                }
            }
            .dsFieldChrome(height: height, cornerRadius: height >= DSControlHeight.large ? 8 : DSCornerRadius.field,
                           isFocused: isFocused, isInvalid: validation != nil,
                           horizontalPadding: height >= DSControlHeight.large ? 10 : DSSpacing.sm)
            .frame(width: controlWidth)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }

            if let validation {
                DSValidationMessage(validation,
                                    identifier: validationIdentifier ?? "ds.textfield.\(identifier).error")
            }
        }
    }
}
