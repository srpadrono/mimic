import DesignSystem
import SwiftUI

/// Names a new, empty journey. Steps are added afterwards in the editor.
///
/// Follows the shared sheet convention: a sentence-case heading inside the sheet, `DSSpacing.lg`
/// between the heading, the fields and the button row, `DSSpacing.lg` of outer padding, and a
/// trailing button row with cancel to the left of the confirm action. The explanatory line sits
/// `DSSpacing.sm` under the heading, the way a macOS dialog puts its message under its title.
struct NewJourneySheet: View {
    @Environment(\.dismiss) private var dismiss

    let onCreate: (String) -> Void

    /// Which field the sheet opens on. Typing has to work the moment the sheet appears; making the
    /// user click into the first field first is a step macOS never asks for.
    private enum Field: Hashable {
        case name
    }

    @State private var name = ""
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text("New journey")
                    .font(DSTypography.title)
                    .foregroundStyle(DSColors.labelPrimary)

                Text("A journey scripts an ordered sequence of responses, so the same endpoint can answer "
                    + "differently depending on where the request falls in the flow.")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The design system's field rather than a bare `.roundedBorder` one, so this sheet's
            // input looks like the input in every other sheet. No `.accessibilityLabel` on the
            // wrapper: `DSTextField` already labels its own input, and a label here would shadow the
            // validation text it shows underneath.
            DSTextField(
                "Name",
                text: $name,
                placeholder: "e.g. Checkout retries",
                identifier: "newJourney.name"
            )
            .accessibilityIdentifier("newJourney.nameField")
            .focused($focusedField, equals: .name)
            .onSubmit(create)

            HStack(spacing: DSSpacing.md) {
                Spacer()
                DSButton(
                    "Cancel",
                    variant: .ghost,
                    size: .medium,
                    identifier: "newJourney.cancel",
                    action: dismiss.callAsFunction
                )
                .accessibilityIdentifier("newJourney.cancelButton")
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)

                DSButton(
                    "Create journey",
                    variant: .primary,
                    size: .medium,
                    identifier: "newJourney.create",
                    action: create
                )
                .accessibilityIdentifier("newJourney.createButton")
                .accessibilityLabel("Create journey")
                .disabled(trimmedName.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DSSpacing.lg)
        .frame(minWidth: 420, idealWidth: 420)
        .defaultFocus($focusedField, .name)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        onCreate(trimmedName)
        dismiss()
    }
}
