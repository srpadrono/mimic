import SwiftUI
import Domain
import DesignSystem

/// Edits the same project-scoped commands used by the CLI and control API.
struct BackendSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var primaryPort = ""
    @State private var primaryUpstream = ""
    @State private var editingID: UUID?
    @State private var backendName = ""
    @State private var backendPort = ""
    @State private var backendUpstream = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Server settings")
                .font(DSTypography.title)
            Text("Each local port can forward calls without a mock to its own real backend.")
                .foregroundStyle(DSColors.labelSecondary)

            Form {
                Section("Primary backend") {
                    TextField("Local port", text: $primaryPort)
                        .accessibilityIdentifier("backend.primary.port")
                        .accessibilityLabel("Primary local port")
                    TextField("Real backend URL", text: $primaryUpstream)
                        .accessibilityIdentifier("backend.primary.upstream")
                        .accessibilityLabel("Primary real backend URL")
                    Button("Save primary backend") {
                        guard let port = Int(primaryPort) else { return }
                        _ = appState.configurePrimaryBackend(port: port, upstreamURL: primaryUpstream)
                    }
                    .disabled(Int(primaryPort) == nil)
                    .accessibilityIdentifier("backend.primary.save")
                    .accessibilityLabel("Save primary backend")
                }

                Section("Additional backends") {
                    ForEach(appState.serverConfiguration.backends) { backend in
                        HStack(spacing: DSSpacing.sm) {
                            VStack(alignment: .leading) {
                                Text(backend.name)
                                Text("localhost:\(backend.port) → \(backend.upstreamURL ?? "Pass-through off")")
                                    .foregroundStyle(DSColors.labelSecondary)
                            }
                            Spacer()
                            Button("Edit") { edit(backend) }
                                .accessibilityIdentifier("backend.edit.\(backend.id)")
                                .accessibilityLabel("Edit \(backend.name)")
                            Button("Delete") { _ = appState.deleteBackend(id: backend.id) }
                                .accessibilityIdentifier("backend.delete.\(backend.id)")
                                .accessibilityLabel("Delete \(backend.name)")
                        }
                    }

                    Text(editingID == nil ? "Add backend" : "Edit backend")
                        .font(DSTypography.headline)
                    TextField("Name", text: $backendName)
                        .accessibilityIdentifier("backend.name")
                        .accessibilityLabel("Backend name")
                    TextField("Local port", text: $backendPort)
                        .accessibilityIdentifier("backend.port")
                        .accessibilityLabel("Backend local port")
                    TextField("Real backend URL", text: $backendUpstream)
                        .accessibilityIdentifier("backend.upstream")
                        .accessibilityLabel("Backend real URL")
                    HStack {
                        Button(editingID == nil ? "Add backend" : "Save backend") { saveBackend() }
                            .disabled(backendName.isEmpty || Int(backendPort) == nil)
                            .accessibilityIdentifier("backend.save")
                            .accessibilityLabel(editingID == nil ? "Add backend" : "Save backend")
                        if editingID != nil {
                            Button("Cancel edit") { resetEditor() }
                                .accessibilityIdentifier("backend.cancelEdit")
                                .accessibilityLabel("Cancel edit")
                        }
                    }
                }
            }

            if let error = appState.lastCommandError {
                Text(error)
                    .foregroundStyle(DSColors.destructive)
                    .accessibilityIdentifier("backend.error")
            }
            HStack {
                Text("Changes to local ports take effect when you restart the server.")
                    .foregroundStyle(DSColors.labelSecondary)
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("backend.done")
                    .accessibilityLabel("Done")
            }
        }
        .padding(DSSpacing.lg)
        .onAppear {
            primaryPort = String(appState.serverConfiguration.port)
            primaryUpstream = appState.serverConfiguration.upstreamURL ?? ""
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backend.settings")
    }

    private func edit(_ backend: BackendConfiguration) {
        editingID = backend.id
        backendName = backend.name
        backendPort = String(backend.port)
        backendUpstream = backend.upstreamURL ?? ""
    }

    private func saveBackend() {
        guard let port = Int(backendPort) else { return }
        let saved: Bool
        if let editingID {
            saved = appState.updateBackend(id: editingID, name: backendName, port: port, upstreamURL: backendUpstream)
        } else {
            saved = appState.addBackend(name: backendName, port: port, upstreamURL: backendUpstream)
        }
        if saved { resetEditor() }
    }

    private func resetEditor() {
        editingID = nil
        backendName = ""
        backendPort = ""
        backendUpstream = ""
    }
}
