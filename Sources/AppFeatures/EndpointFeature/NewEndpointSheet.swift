import SwiftUI
import Domain
import DesignSystem

/// Sheet for creating a new endpoint — method, name, and path.
///
/// Follows the shared sheet convention: a sentence-case heading inside the sheet, `DSSpacing.lg`
/// between the heading, the fields and the button row, `DSSpacing.md` between field rows,
/// `DSSpacing.lg` of outer padding, and a trailing button row with cancel to the left of the
/// confirm action. Errors are shown under the field that caused them rather than in an alert.
struct NewEndpointSheet: View {
    let onConfirm: (String, HTTPMethod, String) -> Void

    public init(onConfirm: @escaping (String, HTTPMethod, String) -> Void) {
        self.onConfirm = onConfirm
    }

    @Environment(\.dismiss) private var dismiss

    /// Which field the sheet opens on. Typing has to work the moment the sheet appears; making the
    /// user click into the first field first is a step macOS never asks for.
    private enum Field: Hashable {
        case name
        case path
    }

    @State private var name = ""
    @State private var method: HTTPMethod = .get
    @State private var path = "/"
    @State private var pathError: String?
    @FocusState private var focusedField: Field?

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && path.hasPrefix("/")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("New endpoint")
                .font(DSTypography.title)
                .foregroundStyle(DSColors.labelPrimary)

            VStack(alignment: .leading, spacing: DSSpacing.md) {
                // No `.accessibilityLabel` here on purpose: `DSTextField` already labels its own
                // input, and a label on the wrapper would shadow the validation text underneath it —
                // VoiceOver would repeat the field name instead of reading the error.
                DSTextField(
                    "Name",
                    text: $name,
                    placeholder: "e.g. Get users",
                    identifier: "newEndpoint.name"
                )
                .accessibilityIdentifier("newEndpoint.nameField")
                .focused($focusedField, equals: .name)
                .onSubmit { confirmIfValid() }

                // Method and path share a row: the two of them are one answer to "which request?".
                HStack(alignment: .top, spacing: DSSpacing.md) {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text("Method")
                            .font(DSTypography.label)
                            .foregroundStyle(DSColors.labelSecondary)
                        Picker("Method", selection: $method) {
                            ForEach(HTTPMethod.allCases, id: \.self) { method in
                                Text(method.rawValue).tag(method)
                            }
                        }
                        .labelsHidden()
                        // Left at AppKit's own height on purpose, and it does not match the field
                        // beside it. Rendered and measured in sRGB, a `Picker` stands **24pt** at
                        // `.regular`, 20 at `.small` and 16 at `.mini`; `DSTextField` is 22. There is
                        // no size that lines up, so this row's two controls end two points apart at
                        // the bottom and that is the smallest available mismatch.
                        //
                        // `.frame(height: 22)` looks like the fix and is not: an `NSPopUpButton` has
                        // a minimum intrinsic height, so the frame only *centres* a 24pt control in a
                        // 22pt slot — the picker then overhangs the row by a point at the top as well
                        // as at the bottom, which is strictly worse than being flush at the top.
                        // `.controlSize(.small)` reaches 20 but takes the label down to 11pt, so
                        // "GET" would be smaller than the path it qualifies.
                        //
                        // Stated here so the next audit does not re-flag it.
                        .accessibilityIdentifier("newEndpoint.methodPicker")
                        .accessibilityLabel("HTTP method")
                    }

                    DSTextField(
                        "Path",
                        text: $path,
                        placeholder: "/api/v1/users",
                        validation: pathError,
                        identifier: "newEndpoint.path"
                    )
                    .accessibilityIdentifier("newEndpoint.pathField")
                    .focused($focusedField, equals: .path)
                    .onSubmit { confirmIfValid() }
                    .onChange(of: path) {
                        pathError = (path.isEmpty || path.hasPrefix("/")) ? nil : "Path must start with '/'"
                    }
                }
            }

            HStack(spacing: DSSpacing.md) {
                Spacer()
                DSButton(
                    "Cancel",
                    variant: .ghost,
                    size: .medium,
                    identifier: "newEndpoint.cancel",
                    action: dismiss.callAsFunction
                )
                .accessibilityIdentifier("newEndpoint.cancelButton")
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)

                DSButton(
                    "Add endpoint",
                    variant: .primary,
                    size: .medium,
                    identifier: "newEndpoint.create",
                    action: confirmIfValid
                )
                .accessibilityIdentifier("newEndpoint.createButton")
                .accessibilityLabel("Add endpoint")
                .disabled(!canCreate)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DSSpacing.lg)
        .frame(minWidth: 420, idealWidth: 420)
        .defaultFocus($focusedField, .name)
    }

    private func confirmIfValid() {
        guard canCreate else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        dismiss()
        onConfirm(trimmedName, method, path)
    }
}
