import DesignSystem
import SwiftUI

/// A focused name edit shared by the project, endpoint, journey, and scenario workflows.
struct RenameItemSheet: View {
    let title: String
    let fieldLabel: String
    let identifier: String
    let initialName: String
    let onRename: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var nameIsFocused: Bool

    init(title: String, fieldLabel: String, identifier: String, initialName: String,
         onRename: @escaping (String) -> Void) {
        self.title = title
        self.fieldLabel = fieldLabel
        self.identifier = identifier
        self.initialName = initialName
        self.onRename = onRename
        _name = State(initialValue: initialName)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text(title)
                .font(DSTypography.headline)
                .foregroundStyle(DSColors.labelPrimary)
                .accessibilityAddTraits(.isHeader)

            DSTextField(fieldLabel, text: $name, identifier: "\(identifier).name")
                .focused($nameIsFocused)
                .onSubmit(renameIfValid)

            HStack(spacing: DSSpacing.sm) {
                Spacer()
                DSButton("Cancel", variant: .secondary, size: .large,
                         identifier: "\(identifier).cancel", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("\(identifier).cancel")
                    .accessibilityLabel("Cancel")
                DSButton("Rename", variant: .primary, size: .large,
                         identifier: "\(identifier).confirm", action: renameIfValid)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || trimmedName == initialName)
                    .accessibilityIdentifier("\(identifier).confirm")
                    .accessibilityLabel("Rename")
            }
            .padding(.top, DSSpacing.sm)
        }
        .padding(DSSpacing.xl)
        .frame(minWidth: DSSheetWidth.compact, idealWidth: DSSheetWidth.compact)
        .background(DSColors.sheet)
        .onAppear { nameIsFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func renameIfValid() {
        guard !trimmedName.isEmpty, trimmedName != initialName else { return }
        onRename(trimmedName)
        dismiss()
    }
}
