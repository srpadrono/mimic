import SwiftUI
import DesignSystem

struct NewProjectFormState {
    var projectName: String
    var portString: String

    init(projectName: String = "", portString: String = "8080") {
        self.projectName = projectName
        self.portString = portString
    }

    var portValue: Int? {
        Int(portString)
    }

    var isPortValid: Bool {
        guard let port = portValue else { return false }
        return port >= 1 && port <= 65535
    }

    var canCreate: Bool {
        !projectName.trimmingCharacters(in: .whitespaces).isEmpty && isPortValid
    }

    var confirmedValues: (name: String, port: Int)? {
        guard canCreate, let port = portValue else { return nil }
        return (projectName.trimmingCharacters(in: .whitespaces), port)
    }
}

/// Sheet for creating a new project with name and port fields.
///
/// Follows the shared sheet convention: a sentence-case heading inside the sheet, `DSSpacing.lg`
/// between the heading, the fields and the button row, `DSSpacing.md` between field rows,
/// `DSSpacing.lg` of outer padding, and a trailing button row with cancel to the left of the
/// confirm action. A bad port is explained under the port field rather than in an alert.
struct NewProjectSheet: View {
    let onConfirm: (String, Int) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Which field the sheet opens on. Typing has to work the moment the sheet appears; making the
    /// user click into the first field first is a step macOS never asks for.
    private enum Field: Hashable {
        case name
        case port
    }

    @State private var form: NewProjectFormState
    @FocusState private var focusedField: Field?

    public init(onConfirm: @escaping (String, Int) -> Void) {
        self.init(initialProjectName: "", initialPortString: "8080", onConfirm: onConfirm)
    }

    init(
        initialProjectName: String,
        initialPortString: String,
        onConfirm: @escaping (String, Int) -> Void
    ) {
        self.onConfirm = onConfirm
        _form = State(initialValue: NewProjectFormState(
            projectName: initialProjectName,
            portString: initialPortString
        ))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("New project")
                .font(DSTypography.title)
                .foregroundStyle(DSColors.labelPrimary)

            VStack(alignment: .leading, spacing: DSSpacing.md) {
                // No `.accessibilityLabel` here on purpose: `DSTextField` already labels its own
                // input, and a label on the wrapper would shadow the validation text underneath it —
                // VoiceOver would repeat the field name instead of reading the error.
                DSTextField(
                    "Project name",
                    text: $form.projectName,
                    placeholder: "My API Mock",
                    identifier: "newProject.name"
                )
                .accessibilityIdentifier("projectNameField")
                .focused($focusedField, equals: .name)
                .onSubmit { confirmIfValid() }

                DSTextField(
                    "Server port",
                    text: $form.portString,
                    placeholder: "8080",
                    validation: portValidationMessage,
                    identifier: "newProject.port"
                )
                .accessibilityIdentifier("serverPortField")
                .focused($focusedField, equals: .port)
                .onSubmit { confirmIfValid() }
            }

            HStack(spacing: DSSpacing.md) {
                Spacer()
                DSButton(
                    "Cancel",
                    variant: .ghost,
                    size: .medium,
                    identifier: "newProject.cancel",
                    action: dismiss.callAsFunction
                )
                .accessibilityIdentifier("cancelCreateButton")
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)

                DSButton(
                    "Create project",
                    variant: .primary,
                    size: .medium,
                    identifier: "newProject.create",
                    action: confirmIfValid
                )
                .accessibilityIdentifier("createProjectButton")
                .accessibilityLabel("Create project")
                .disabled(!form.canCreate)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DSSpacing.lg)
        .frame(minWidth: 420, idealWidth: 420)
        .defaultFocus($focusedField, .name)
    }

    /// Silent until there is something to complain about: an empty port field is a form you have not
    /// finished, not a mistake you have made.
    private var portValidationMessage: String? {
        guard !form.portString.isEmpty, !form.isPortValid else { return nil }
        return "Port must be between 1 and 65535"
    }

    var currentForm: NewProjectFormState {
        form
    }

    func confirmIfValid() {
        Self.confirm(form: form, onConfirm: onConfirm, dismiss: dismiss.callAsFunction)
    }

    static func confirm(
        form: NewProjectFormState,
        onConfirm: (String, Int) -> Void,
        dismiss: () -> Void
    ) {
        guard let values = form.confirmedValues else { return }
        dismiss()
        onConfirm(values.name, values.port)
    }
}
