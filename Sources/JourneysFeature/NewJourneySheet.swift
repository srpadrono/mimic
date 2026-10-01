import DesignSystem
import SwiftUI

/// Names a new, empty journey. Steps are added afterwards in the editor.
///
/// Sheet anatomy: 15pt title with a 12pt explanation under it, a form row, and Cancel and the
/// confirm action trailing.
public struct NewJourneySheet: View {
    @Environment(\.dismiss) private var dismiss

    let onCreate: (String) -> Void

    /// Which field the sheet opens on. Typing has to work the moment the sheet appears; making the
    /// user click into the first field first is a step macOS never asks for.
    private enum Field: Hashable {
        case name
    }

    @State private var name = ""
    @FocusState private var focusedField: Field?

    public init(onCreate: @escaping (String) -> Void) {
        self.onCreate = onCreate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("New journey")
                    .font(DSTypography.headline)
                    .foregroundStyle(DSColors.labelPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("newJourney.title")

                Text("A journey scripts an ordered sequence of responses, so the same endpoint can answer "
                    + "differently depending on where the request falls in the flow.")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineSpacing(DSTypography.Leading.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("newJourney.explanation")
            }

            // No `.accessibilityLabel` on the wrapper: `DSTextField` labels its own input, and a
            // label here would hide the validation text under it.
            DSTextField(
                "Name",
                text: $name,
                placeholder: "Checkout retries",
                identifier: "newJourney.name"
            )
            .accessibilityIdentifier("newJourney.nameField")
            .focused($focusedField, equals: .name)
            .onSubmit(create)

            HStack(spacing: DSSpacing.sm) {
                Spacer()
                DSButton(
                    "Cancel",
                    variant: .secondary,
                    size: .large,
                    identifier: "newJourney.cancel",
                    action: dismiss.callAsFunction
                )
                .accessibilityIdentifier("newJourney.cancelButton")
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)

                DSButton(
                    "Create journey",
                    variant: .primary,
                    size: .large,
                    identifier: "newJourney.create",
                    action: create
                )
                .accessibilityIdentifier("newJourney.createButton")
                .accessibilityLabel("Create journey")
                .disabled(trimmedName.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, DSSpacing.sm)
        }
        .padding(DSSpacing.xl)
        .frame(minWidth: DSSheetWidth.compact, idealWidth: DSSheetWidth.compact)
        .background(DSColors.sheet)
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
