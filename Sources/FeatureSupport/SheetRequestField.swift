import DesignSystem
import Domain
import SwiftUI

/// Method and path in one field, as the request sheets show them: a borderless method menu, a
/// hairline, then the path in SF Mono. The validation message sits under the field.
public struct SheetRequestField: View {
    @Binding var method: HTTPMethod
    @Binding var path: String
    let validation: String?
    let pickerIdentifier: String
    let fieldIdentifier: String
    let validationIdentifier: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    /// A green tick and a short fact at the field's trailing edge, such as "Matches an endpoint".
    var matchNote: String?

    public init(
        method: Binding<HTTPMethod>,
        path: Binding<String>,
        validation: String?,
        pickerIdentifier: String,
        fieldIdentifier: String,
        validationIdentifier: String,
        isFocused: FocusState<Bool>.Binding,
        onSubmit: @escaping () -> Void,
        matchNote: String? = nil
    ) {
        _method = method
        _path = path
        self.validation = validation
        self.pickerIdentifier = pickerIdentifier
        self.fieldIdentifier = fieldIdentifier
        self.validationIdentifier = validationIdentifier
        self.isFocused = isFocused
        self.onSubmit = onSubmit
        self.matchNote = matchNote
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: DSSpacing.sm) {
                // A menu rather than a menu-style `Picker`, whose pop-up button draws its own pair of
                // chevrons: the design has the method in its colour and one down chevron.
                Menu {
                    ForEach(HTTPMethod.allCases, id: \.self) { option in
                        Button(option.rawValue) { method = option }
                    }
                } label: {
                    HStack(spacing: DSSpacing.xs) {
                        Text(method.rawValue)
                            .font(DSTypography.method)
                            .foregroundStyle(DSColors.methodColor(for: method.rawValue))
                        Image(systemName: "chevron.down")
                            .font(.system(size: DSGlyph.disclosure, weight: .semibold))
                            .foregroundStyle(DSColors.labelTertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(height: DSControlHeight.regular)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("HTTP method")
                .accessibilityIdentifier(pickerIdentifier)
                .accessibilityLabel("HTTP method")
                .accessibilityValue(method.rawValue)

                Rectangle()
                    .fill(DSColors.separator)
                    .frame(width: DSStroke.hairline)
                    .padding(.vertical, 6)
                    .accessibilityHidden(true)

                TextField("/api/v1/users", text: $path)
                    .textFieldStyle(.plain)
                    .font(DSTypography.codeLarge)
                    .focused(isFocused)
                    .onSubmit(onSubmit)
                    .accessibilityIdentifier(fieldIdentifier)
                    .accessibilityLabel("Path")

                if let matchNote {
                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: "checkmark")
                            .font(.system(size: DSGlyph.disclosure, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(matchNote)
                            .font(DSTypography.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(DSColors.success)
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("\(fieldIdentifier).matchNote")
                }
            }
            // Same radius as `DSTextField` at sheet height, so stacked rows line up.
            .dsFieldChrome(height: DSControlHeight.large, cornerRadius: DSCornerRadius.segment,
                           isFocused: isFocused.wrappedValue, isInvalid: validation != nil,
                           horizontalPadding: DSSpacing.sm)

            if let validation {
                DSValidationMessage(validation, identifier: validationIdentifier)
            }
        }
    }
}
