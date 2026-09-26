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
                .font(DSTypography.title)
                .foregroundStyle(DSColors.labelPrimary)

            DSTextField(fieldLabel, text: $name, identifier: "\(identifier).name")
                .focused($nameIsFocused)
                .onSubmit(renameIfValid)

            HStack(spacing: DSSpacing.md) {
                Spacer()
                DSButton("Cancel", variant: .ghost, size: .medium,
                         identifier: "\(identifier).cancel", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("\(identifier).cancel")
                    .accessibilityLabel("Cancel")
                DSButton("Rename", variant: .primary, size: .medium,
                         identifier: "\(identifier).confirm", action: renameIfValid)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || trimmedName == initialName)
                    .accessibilityIdentifier("\(identifier).confirm")
                    .accessibilityLabel("Rename")
            }
        }
        .padding(DSSpacing.lg)
        .frame(minWidth: DSSheetWidth.compact, idealWidth: DSSheetWidth.compact)
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
