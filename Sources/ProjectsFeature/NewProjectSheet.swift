import SwiftUI
import DesignSystem
import FeatureSupport

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
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isPortValid
    }

    var confirmedValues: (name: String, port: Int)? {
        guard canCreate, let port = portValue else { return nil }
        return (projectName.trimmingCharacters(in: .whitespacesAndNewlines), port)
    }
}

/// Sheet for creating a new project with name and port fields.
///
/// Headline title, form rows with right-aligned labels, and a trailing Cancel / Create row. A bad
/// port is explained under the port field rather than in an alert.
public struct NewProjectSheet: View {
    let onConfirm: (String, Int) -> Void
    /// Draws the Name field focused without keyboard focus, for the gallery's off-screen render.
    let showsNameFocus: Bool

    @Environment(\.dismiss) private var dismiss

    /// Typing has to work the moment the sheet appears.
    private enum Field: Hashable {
        case name
        case port
    }

    @State private var form: NewProjectFormState
    @FocusState private var focusedField: Field?
    /// Whether the typed port can be bound right now; `nil` while the port is not a valid number.
    @State private var portIsAvailable: Bool?

    public init(onConfirm: @escaping (String, Int) -> Void) {
        self.init(initialProjectName: "", initialPortString: "8080", onConfirm: onConfirm)
    }

    /// Opens with the fields already filled, as a preview or the gallery shows it. `showsNameFocus`
    /// draws the Name field's focus ring, as the design does, where no window can hold focus.
    public init(
        initialProjectName: String,
        initialPortString: String,
        showsNameFocus: Bool = false,
        onConfirm: @escaping (String, Int) -> Void
    ) {
        self.onConfirm = onConfirm
        self.showsNameFocus = showsNameFocus
        _form = State(initialValue: NewProjectFormState(
            projectName: initialProjectName,
            portString: initialPortString
        ))
    }

    /// The board's 15/20 title line.
    private static let titleLineHeight: CGFloat = 20
    /// The board's `.btn` is content-box: a 28pt capsule and its hairline border make a 29pt row.
    private static let buttonRowHeight: CGFloat = DSControlHeight.large + 1

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("New project")
                .font(DSTypography.headline)
                .frame(height: Self.titleLineHeight)
                .foregroundStyle(DSColors.labelPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                // `DSTextField` labels its own input; a label on the wrapper would hide the
                // validation text from VoiceOver.
                DSTextField(
                    "Name",
                    text: $form.projectName,
                    placeholder: "My API Mock",
                    identifier: "newProject.name"
                )
                .accessibilityIdentifier("projectNameField")
                .environment(\.dsShowsFocus, showsNameFocus)
                .focused($focusedField, equals: .name)
                .onSubmit { confirmIfValid() }

                VStack(alignment: .leading, spacing: DSFormMetrics.sheetHintGap) {
                    DSFormRow("Port", alignment: .top) {
                        HStack(alignment: .top, spacing: DSSpacing.md) {
                            DSTextField(
                                "Port",
                                text: $form.portString,
                                placeholder: "8080",
                                validation: portValidationMessage,
                                validationIdentifier: "newProject.port.error",
                                controlWidth: DSFormMetrics.sheetPortFieldWidth,
                                inputIdentifier: "serverPortField",
                                monospaced: true,
                                labelPlacement: .hidden,
                                identifier: "newProject.port"
                            )
                            .focused($focusedField, equals: .port)
                            .onSubmit { confirmIfValid() }

                            if let portIsAvailable {
                                DSAvailabilityLabel(
                                    isAvailable: portIsAvailable,
                                    identifier: "newProject.port.availability"
                                )
                                // Centred on the 28pt field rather than on the row, which grows
                                // when a validation message appears under the field.
                                .frame(height: DSControlHeight.large)
                            }
                        }
                    }

                    DSFormHint(portHint)
                        .accessibilityIdentifier("newProject.port.hint")
                }
            }

            HStack(spacing: DSSpacing.sm) {
                Spacer()
                DSButton(
                    "Cancel",
                    variant: .secondary,
                    size: .large,
                    identifier: "newProject.cancel",
                    action: dismiss.callAsFunction
                )
                .accessibilityIdentifier("cancelCreateButton")
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)

                DSButton(
                    "Create project",
                    variant: .primary,
                    size: .large,
                    identifier: "newProject.create",
                    action: confirmIfValid
                )
                .accessibilityIdentifier("createProjectButton")
                .accessibilityLabel("Create project")
                .disabled(!form.canCreate)
                .keyboardShortcut(.defaultAction)
            }
            .frame(height: Self.buttonRowHeight)
            .padding(.top, DSSpacing.sm)
        }
        .padding(DSSpacing.xl)
        .frame(width: DSSheetWidth.short)
        .background(DSColors.sheet)
        .dsSheetSurface()
        .defaultFocus($focusedField, .name)
        // Re-probed as the port is typed, after a pause so each keystroke is not a bind.
        .task(id: form.portString) {
            guard form.isPortValid, let port = form.portValue else {
                portIsAvailable = nil
                return
            }
            if portIsAvailable != nil {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            portIsAvailable = PortProbe.isAvailable(port)
        }
    }

    /// Where the app under test should point, once the port is usable.
    private var portHint: String {
        guard form.isPortValid, let port = form.portValue else {
            return "Your app connects to this port on localhost."
        }
        return "Your app connects to http://localhost:\(port)."
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
