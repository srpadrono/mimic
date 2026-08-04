import SwiftUI

/// Text input with label, focus ring, and validation state.
///
/// The field wears the workspace's control shape: `DSCornerRadius.sm`, a 0.5pt `DSColors.border`
/// hairline and 3pt above and below the text. It stands 22pt rather than the 20pt a panel-header
/// control takes, because 20pt cannot hold a 13pt line honestly.
///
/// This used to claim 22 was also "what AppKit gives a regular-size `Picker`, which is the control
/// this field is most often placed beside". It is not. Rendered and measured in sRGB, a `Picker`
/// stands **24pt** at `.regular`, 20 at `.small` and 16 at `.mini` — so on the one row where the two
/// genuinely sit side by side, the method picker and the path field in `NewEndpointSheet`, they end
/// two points apart and no picker size closes the gap. The number here is still right for a 13pt
/// line; only the justification was wrong, and the mismatch is written down at that call site rather
/// than papered over with a frame the popup ignores.
///
/// The border used to be 1pt at rest and 1.5pt focused, which put a form-weight rule around every
/// input while the wells beside them wore hairlines; the field now differs from its neighbours by
/// *state* — accent when focused, destructive when invalid — and by nothing else.
public struct DSTextField: View {
    /// One 13pt line plus `verticalPadding` above and below.
    private static let controlHeight: CGFloat = 22
    private static let verticalPadding: CGFloat = 3

    private let label: String
    @Binding private var text: String
    private let placeholder: String
    private let validation: String?
    private let identifier: String
    @FocusState private var isFocused: Bool

    public init(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        validation: String? = nil,
        identifier: String
    ) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.validation = validation
        self.identifier = identifier
    }

    public var body: some View {
        // Deliberately *not* an accessibility container. This view carries no identifier of its own,
        // and callers stamp theirs on the whole field — `NewProjectSheet` tags it `serverPortField`,
        // which the UI suite then looks up as `app.textFields[…]`. Making the stack a container
        // would move that identifier onto a group element and the text-field lookup would find
        // nothing.
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(label)
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelSecondary)
                .accessibilityIdentifier("ds.textfield.\(identifier).label")

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DSTypography.body)
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, Self.verticalPadding)
                .frame(height: Self.controlHeight)
                .focused($isFocused)
                .background {
                    RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                        .fill(DSColors.tertiary)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                        .stroke(borderColor, lineWidth: isFocused ? 1 : 0.5)
                }
                .animation(.easeOut(duration: DSAnimation.fast), value: isFocused)
                .accessibilityIdentifier("ds.textfield.\(identifier)")
                .accessibilityLabel(label)

            if let validation {
                validationRow(validation)
            }
        }
    }

    /// The message sits under the field it is about, and says so with a glyph as well as a colour.
    ///
    /// Red 11pt text on its own is a single channel of meaning: with Differentiate Without Color on,
    /// in a greyscale screenshot, or to a reader with a red deficiency, an invalid field and a hint
    /// look the same. The glyph is the part that survives all three.
    private func validationRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))

            // Wraps rather than truncates. The path field shares its row with a method picker, so
            // the message can be given well under its ideal width — and a validation message that
            // ends in an ellipsis is a validation message that has stopped explaining itself.
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(DSTypography.label)
        .foregroundStyle(DSColors.destructive)
        // One reading, not a glyph and a sentence read separately.
        .accessibilityElement()
        .accessibilityLabel(message)
        .accessibilityIdentifier("ds.textfield.\(identifier).error")
    }

    private var borderColor: Color {
        if validation != nil { return DSColors.destructive }
        if isFocused { return DSColors.borderFocused }
        return DSColors.border
    }
}
