import SwiftUI
import Domain
import DesignSystem

/// What the new-endpoint sheet hands back: the request, its name, where it is grouped, and what the
/// default scenario answers with.
struct NewEndpointDraft: Equatable {
    var name: String
    var method: HTTPMethod
    var path: String
    /// `nil` when the endpoint joins no group.
    var groupTag: String?
    var statusCode: Int
    var contentType: Scenario.ContentType
}

/// Sheet for creating a new endpoint: the request (method and path in one field), a name and a
/// group, then the status and content type its default scenario answers with.
///
/// Sheet anatomy: 15pt title, form rows with a right-aligned label column, and Cancel and the
/// confirm action trailing. Errors show under the field that caused them, not in an alert.
struct NewEndpointSheet: View {
    /// Codes the status menu offers. Any other code can be set in the editor afterwards.
    static let statusCodes = [200, 201, 202, 204, 301, 302, 304, 400, 401, 403, 404, 409, 422, 429, 500, 502, 503, 504]
    /// The width the design gives the status and content-type fields.
    static let responseFieldWidth: CGFloat = 180

    let existingGroups: [String]
    let onConfirm: (NewEndpointDraft) -> Void

    public init(existingGroups: [String] = [], onConfirm: @escaping (NewEndpointDraft) -> Void) {
        self.existingGroups = existingGroups
        self.onConfirm = onConfirm
    }

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var method: HTTPMethod = .get
    @State private var path = "/"
    @State private var groupTag = ""
    @State private var statusCode = 200
    @State private var contentType: Scenario.ContentType = .json
    /// The sheet opens with the request field focused, so typing works at once.
    @FocusState private var pathIsFocused: Bool
    @FocusState private var groupIsFocused: Bool

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

            DSFormRow("Group") { groupField }

            DSDivider(identifier: "newEndpoint.response")

            DSFormRow("Status") { statusField }

            DSFormRow("Content type") { contentTypeField }

            footer
                .padding(.top, DSSpacing.sm)
        }
        .padding(DSSpacing.xl)
        .frame(minWidth: DSSheetWidth.compact, idealWidth: DSSheetWidth.compact)
        .background(DSColors.sheet)
        .defaultFocus($pathIsFocused, true)
    }

    // MARK: - Group, status and content type

    /// Free text, with the project's existing groups one click away.
    private var groupField: some View {
        HStack(spacing: DSSpacing.xs) {
            TextField("None", text: $groupTag)
                .textFieldStyle(.plain)
                .font(DSTypography.body)
                .focused($groupIsFocused)
                .onSubmit(confirmIfValid)
                .accessibilityIdentifier("newEndpoint.group")
                .accessibilityLabel("Group")
            if !existingGroups.isEmpty {
                Menu {
                    ForEach(existingGroups, id: \.self) { group in
                        Button(group) { groupTag = group }
                    }
                    Divider()
                    Button("No group") { groupTag = "" }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: DSGlyph.disclosure, weight: .semibold))
                        .foregroundStyle(DSColors.labelTertiary)
                        .frame(width: DSGlyph.field + DSSpacing.xs, height: DSControlHeight.regular)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose an existing group")
                .accessibilityIdentifier("newEndpoint.groupMenu")
                .accessibilityLabel("Existing groups")
            }
        }
        .dsFieldChrome(height: DSControlHeight.large, cornerRadius: DSCornerRadius.segment,
                       isFocused: groupIsFocused)
    }

    /// The code in its status colour with the reason phrase beside it, chosen from a menu.
    private var statusField: some View {
        Menu {
            ForEach(Self.statusCodes, id: \.self) { code in
                Button("\(code) \(EndpointEditorView.reasonPhrase(for: code))") { statusCode = code }
                    .accessibilityIdentifier("newEndpoint.status.\(code)")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(DSColors.httpStatusColor(for: statusCode))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(verbatim: String(statusCode))
                    .font(DSTypography.status)
                    .foregroundStyle(DSColors.httpStatusColor(for: statusCode))
                Text(EndpointEditorView.reasonPhrase(for: statusCode))
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                disclosureGlyph
            }
            .dsFieldChrome(height: DSControlHeight.large, cornerRadius: DSCornerRadius.segment, isFocused: false)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: Self.responseFieldWidth)
        .help("The status the default scenario answers with")
        .accessibilityIdentifier("newEndpoint.status")
        .accessibilityLabel("Status")
        .accessibilityValue("\(statusCode) \(EndpointEditorView.reasonPhrase(for: statusCode))")
    }

    private var contentTypeField: some View {
        Menu {
            Button("JSON") { contentType = .json }
                .accessibilityIdentifier("newEndpoint.contentType.json")
            Button("Plain text") { contentType = .plainText }
                .accessibilityIdentifier("newEndpoint.contentType.plainText")
        } label: {
            HStack(spacing: DSSpacing.xs) {
                Text(Self.contentTypeTitle(contentType))
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                disclosureGlyph
            }
            .dsFieldChrome(height: DSControlHeight.large, cornerRadius: DSCornerRadius.segment, isFocused: false)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: Self.responseFieldWidth)
        .help("The content type of the default scenario's body")
        .accessibilityIdentifier("newEndpoint.contentType")
        .accessibilityLabel("Content type")
        .accessibilityValue(Self.contentTypeTitle(contentType))
    }

    private var disclosureGlyph: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: DSGlyph.disclosure, weight: .semibold))
            .foregroundStyle(DSColors.labelTertiary)
            .accessibilityHidden(true)
    }

    static func contentTypeTitle(_ contentType: Scenario.ContentType) -> String {
        switch contentType {
        case .json: "JSON"
        case .plainText: "Plain text"
        }
    }

    /// The draft the sheet confirms, or `nil` while it cannot be created. A group that is only
    /// whitespace is no group.
    static func draft(
        name: String,
        method: HTTPMethod,
        path: String,
        groupTag: String,
        statusCode: Int,
        contentType: Scenario.ContentType
    ) -> NewEndpointDraft? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, (try? EndpointValidator.validatePath(path)) != nil else { return nil }
        let trimmedGroup = groupTag.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewEndpointDraft(
            name: trimmedName,
            method: method,
            path: path,
            groupTag: trimmedGroup.isEmpty ? nil : trimmedGroup,
            statusCode: statusCode,
            contentType: contentType
        )
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
        guard canCreate, let draft = Self.draft(
            name: name, method: method, path: path,
            groupTag: groupTag, statusCode: statusCode, contentType: contentType
        ) else { return }
        dismiss()
        onConfirm(draft)
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
    /// A green tick and a short fact at the field's trailing edge, such as "Matches an endpoint".
    var matchNote: String? = nil

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

                if let matchNote {
                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: "checkmark")
                            .font(.system(size: DSGlyph.disclosure, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(matchNote)
                            .font(DSTypography.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(DSColors.success)
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("\(fieldIdentifier).matchNote")
                }
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
