import DesignSystem
import Domain
import SwiftUI

/// Edits the request an existing endpoint matches. Response and backend stay in their own editor.
struct EndpointRequestSheet: View {
    let endpoint: Endpoint
    let onSave: (EndpointSpec) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var method: HTTPMethod
    @State private var path: String
    @State private var graphqlOperation: String
    @FocusState private var pathIsFocused: Bool

    init(endpoint: Endpoint, onSave: @escaping (EndpointSpec) -> Void) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("Edit request")
                .font(DSTypography.title)
                .foregroundStyle(DSColors.labelPrimary)

            VStack(alignment: .leading, spacing: DSSpacing.md) {
                DSFormPicker("Method", selection: $method, identifier: "endpointRequest.method") {
                    ForEach(HTTPMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                DSTextField("Path", text: $path, validation: pathError,
                            identifier: "endpointRequest.path")
                    .focused($pathIsFocused)
                    .onSubmit(saveIfValid)
                DSTextField("GraphQL operation", text: $graphqlOperation,
                            placeholder: "Any operation", identifier: "endpointRequest.operation")
                    .onSubmit(saveIfValid)
            }

            HStack(spacing: DSSpacing.md) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("endpointRequest.cancel")
                Button("Save", action: saveIfValid)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pathError != nil || !hasChanges)
                    .accessibilityIdentifier("endpointRequest.save")
            }
        }
        .padding(DSSpacing.lg)
        .frame(width: 420)
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
