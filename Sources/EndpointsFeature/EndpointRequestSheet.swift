import DesignSystem
import Domain
import SwiftUI
import FeatureSupport

/// Edits the request an existing endpoint matches. Response and backend stay in their own editor.
public struct EndpointRequestSheet: View {
    let endpoint: Endpoint
    let onSave: (EndpointSpec) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var method: HTTPMethod
    @State private var path: String
    @State private var graphqlOperation: String
    @FocusState private var pathIsFocused: Bool

    public init(endpoint: Endpoint, onSave: @escaping (EndpointSpec) -> Void) {
        self.endpoint = endpoint
        self.onSave = onSave
        _method = State(initialValue: endpoint.method)
        _path = State(initialValue: endpoint.path)
        _graphqlOperation = State(initialValue: endpoint.graphqlOperation ?? "")
    }

    private var pathError: String? {
        guard !path.isEmpty else { return "Enter a path." }
        guard path.hasPrefix("/") else { return "Path must start with '/'." }
        do {
            try EndpointValidator.validatePath(path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var hasChanges: Bool {
        method != endpoint.method || path != endpoint.path
            || graphqlOperation != (endpoint.graphqlOperation ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("Edit request")
                .font(DSTypography.headline)
                .foregroundStyle(DSColors.labelPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 6) {
                DSFormRow("Request", alignment: .top) {
                    SheetRequestField(
                        method: $method,
                        path: $path,
                        validation: pathError,
                        pickerIdentifier: "endpointRequest.method",
                        fieldIdentifier: "ds.textfield.endpointRequest.path",
                        validationIdentifier: "ds.textfield.endpointRequest.path.error",
                        isFocused: $pathIsFocused,
                        onSubmit: saveIfValid
                    )
                }
                if pathError == nil {
                    DSFormHint("Use :name for a path parameter, like :id.")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                DSTextField("GraphQL operation", text: $graphqlOperation,
                            placeholder: "Any operation", identifier: "endpointRequest.operation")
                    .onSubmit(saveIfValid)
                DSFormHint("Leave empty to match every operation on this path.")
            }

            HStack(spacing: DSSpacing.sm) {
                Spacer()
                DSButton("Cancel", variant: .secondary, size: .large,
                         identifier: "endpointRequest.cancel", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("endpointRequest.cancel")
                    .accessibilityLabel("Cancel")
                DSButton("Save", variant: .primary, size: .large,
                         identifier: "endpointRequest.save", action: saveIfValid)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pathError != nil || !hasChanges)
                    .accessibilityIdentifier("endpointRequest.save")
                    .accessibilityLabel("Save")
            }
            .padding(.top, DSSpacing.sm)
        }
        .padding(DSSpacing.xl)
        .frame(width: DSSheetWidth.compact)
        .background(DSColors.sheet)
        .dsSheetSurface()
        .onAppear { pathIsFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("endpointRequest")
    }

    private func saveIfValid() {
        guard pathError == nil, hasChanges else { return }
        onSave(EndpointSpec(
            method: method,
            path: path,
            graphqlOperation: graphqlOperation == (endpoint.graphqlOperation ?? "")
                ? nil : graphqlOperation
        ))
        dismiss()
    }
}
