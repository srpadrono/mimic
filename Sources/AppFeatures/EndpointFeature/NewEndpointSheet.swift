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
                    DSFormPicker("Method", selection: $method, identifier: "newEndpoint.methodPicker") {
                        ForEach(HTTPMethod.allCases, id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    // AppKit's regular picker is 24pt beside the field's 22pt well. Pinning its
                    // frame to 22 would centre the 24pt control and misalign both edges; keeping
                    // their top edges aligned is the cleaner native arrangement.
                    .accessibilityLabel("HTTP method")

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
        .frame(minWidth: DSSheetWidth.compact, idealWidth: DSSheetWidth.compact)
        .defaultFocus($focusedField, .name)
    }

    private func confirmIfValid() {
        guard canCreate else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        dismiss()
        onConfirm(trimmedName, method, path)
    }
}
