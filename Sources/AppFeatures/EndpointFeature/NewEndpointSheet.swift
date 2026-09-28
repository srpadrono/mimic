import SwiftUI
import Domain
import DesignSystem

/// Sheet for creating a new endpoint: the request (method and path in one field), then a name.
///
/// Sheet anatomy: 15pt title, form rows with a right-aligned label column, and Cancel and the
/// confirm action trailing. Errors show under the field that caused them, not in an alert.
struct NewEndpointSheet: View {
    let onConfirm: (String, HTTPMethod, String) -> Void

    public init(onConfirm: @escaping (String, HTTPMethod, String) -> Void) {
        self.onConfirm = onConfirm
    }

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var method: HTTPMethod = .get
    @State private var path = "/"
    /// The sheet opens with the request field focused, so typing works at once.
    @FocusState private var pathIsFocused: Bool

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pathError == nil
    }

    private var pathError: String? {
        do {
            try EndpointValidator.validatePath(path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("New endpoint")
                .font(DSTypography.headline)
                .foregroundStyle(DSColors.labelPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 6) {
                DSFormRow("Request", alignment: .top) {
                    SheetRequestField(
                        method: $method,
                        path: $path,
                        validation: pathError,
                        pickerIdentifier: "newEndpoint.methodPicker",
                        fieldIdentifier: "newEndpoint.pathField",
                        validationIdentifier: "newEndpoint.path.error",
                        isFocused: $pathIsFocused,
                        onSubmit: confirmIfValid
                    )
                }
                if pathError == nil {
                    DSFormHint("Use :name for a path parameter, like :id.")
                }
            }

            // No `.accessibilityLabel` on the wrapper: `DSTextField` labels its own input, and a
            // label here would hide the validation text under it.
            DSTextField(
                "Name",
                text: $name,
                placeholder: "Get product",
                identifier: "newEndpoint.name"
            )
            .accessibilityIdentifier("newEndpoint.nameField")
            .onSubmit { confirmIfValid() }

            footer
                .padding(.top, DSSpacing.sm)
        }
        .padding(DSSpacing.xl)
        .frame(minWidth: DSSheetWidth.compact, idealWidth: DSSheetWidth.compact)
        .background(DSColors.sheet)
        .defaultFocus($pathIsFocused, true)
    }

    private var footer: some View {
        HStack(spacing: DSSpacing.sm) {
            Spacer()
            DSButton(
                "Cancel",
                variant: .secondary,
                size: .large,
                identifier: "newEndpoint.cancel",
                action: dismiss.callAsFunction
            )
            .accessibilityIdentifier("newEndpoint.cancelButton")
            .accessibilityLabel("Cancel")
            .keyboardShortcut(.cancelAction)

            DSButton(
                "Add endpoint",
                variant: .primary,
                size: .large,
                identifier: "newEndpoint.create",
                action: confirmIfValid
            )
            .accessibilityIdentifier("newEndpoint.createButton")
            .accessibilityLabel("Add endpoint")
            .disabled(!canCreate)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func confirmIfValid() {
        guard canCreate else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
        onConfirm(trimmedName, method, path)
    }
}

/// Method and path in one field, as the request sheets show them: a borderless method menu, a
/// hairline, then the path in SF Mono. The validation message sits under the field.
struct SheetRequestField: View {
    @Binding var method: HTTPMethod
    @Binding var path: String
    let validation: String?
    let pickerIdentifier: String
    let fieldIdentifier: String
    let validationIdentifier: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: DSSpacing.sm) {
                Picker("HTTP method", selection: $method) {
                    ForEach(HTTPMethod.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .buttonStyle(.borderless)
                .fixedSize()
                .font(DSTypography.method)
                .tint(DSColors.methodColor(for: method.rawValue))
                .accessibilityIdentifier(pickerIdentifier)
                .accessibilityLabel("HTTP method")

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
