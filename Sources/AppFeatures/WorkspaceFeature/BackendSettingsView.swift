import SwiftUI
import AppKit
import Domain
import DesignSystem

/// A single draft: validation and publication use the same atomic command as automation.
struct BackendSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ServerConfiguration
    @State private var portText: [String: String] = [:]
    @State private var error: String?
    @State private var newestBackendID: UUID?

    init(configuration: ServerConfiguration) {
        _draft = State(initialValue: configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                HStack {
                    Text("Server settings").font(DSTypography.title)
                    Spacer()
                    // Keep the creation action outside the scrolling Form. On a short display,
                    // a click on its last row can be consumed while dismissing field focus.
                    DSButton("Add backend", variant: .secondary, size: .small, identifier: "backend.add") {
                        addBackend()
                    }
                    .accessibilityIdentifier("backend.add")
                    .accessibilityLabel("Add backend")
                }
                Text("Point your app to each local URL. Mimic serves your mocks first, then forwards other calls to the real backend.")
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollViewReader { scrollProxy in
                Form {
                    Section("Primary backend") {
                        fields(name: $draft.primaryName, port: $draft.port, upstream: $draft.upstreamURL,
                               enabled: $draft.passthroughEnabled, capture: $draft.captureResponses, prefix: "backend.primary")
                    }
                    ForEach($draft.backends) { $backend in
                        Section {
                            fields(name: $backend.name, port: $backend.port, upstream: $backend.upstreamURL,
                                   enabled: $backend.passthroughEnabled, capture: $backend.captureResponses,
                                   prefix: "backend.\(backend.id)")
                            Button("Remove backend", role: .destructive) {
                                draft.backends.removeAll { $0.id == backend.id }
                            }
                            .accessibilityIdentifier("backend.delete.\(backend.id)")
                            .accessibilityLabel("Remove \(backend.name)")
                        } header: { Text(backend.name.isEmpty ? "New backend" : backend.name) }
                            .id(backend.id)
                    }
                }
                .formStyle(.grouped)
                .onChange(of: newestBackendID) { _, id in
                    guard let id else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        scrollProxy.scrollTo(id, anchor: .top)
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(DSColors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("backend.error")
            }
            HStack(spacing: DSSpacing.md) {
                Text("Backend URLs and pass-through changes apply immediately. Adding, removing, or changing a local port requires a server restart.")
                    .font(DSTypography.caption).foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DSSpacing.md)
                DSButton("Cancel", variant: .ghost, size: .medium, identifier: "backend.cancel") {
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("backend.cancel")
                    .accessibilityLabel("Cancel settings changes")
                DSButton("Apply", variant: .primary, size: .medium, identifier: "backend.apply") {
                    if appState.applyServerConfiguration(draft) { dismiss() }
                    else { error = appState.lastCommandError }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("backend.apply")
                .accessibilityLabel("Apply server settings")
            }
        }
        .padding(DSSpacing.lg)
        // One backend should not leave a large empty scroll region. Grow the sheet as listeners
        // are added, then let the form scroll once the window reaches a practical height.
        .frame(
            width: BackendSettingsGeometry.width,
            height: BackendSettingsGeometry.height(
                forBackendCount: draft.backends.count,
                visibleScreenHeight: NSScreen.main?.visibleFrame.height ?? 900
            )
        )
        // The form's dynamic sections must keep the identifiers on their individual fields.
        // A parent identifier can flatten onto newly realized rows on compact AppKit forms.
        .accessibilityElement(children: .contain)
    }

    private func addBackend() {
        let used = Set(draft.listeners.map(\.port))
        let port = (8081...65535).first { !used.contains($0) } ?? 8081
        let backend = BackendConfiguration(name: "New backend", port: port)
        draft.backends.append(backend)
        newestBackendID = backend.id
    }

    @ViewBuilder
    private func fields(name: Binding<String>, port: Binding<Int>, upstream: Binding<String?>,
                        enabled: Binding<Bool>, capture: Binding<Bool>, prefix: String) -> some View {
        TextField("Name", text: name)
            .accessibilityIdentifier(prefix + ".name").accessibilityLabel("Backend name")
        TextField("Local port", text: Binding(get: { portText[prefix] ?? String(port.wrappedValue) }, set: {
            portText[prefix] = $0
            port.wrappedValue = Int($0) ?? 0
        }))
            .accessibilityIdentifier(prefix + ".port").accessibilityLabel("Local port")
        LabeledContent("App connects to") {
            HStack {
                Text("http://localhost:\(String(port.wrappedValue))").textSelection(.enabled)
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("http://localhost:\(port.wrappedValue)", forType: .string)
                }
                .accessibilityIdentifier(prefix + ".copy").accessibilityLabel("Copy local URL")
            }
        }
        Toggle("Pass through unmatched requests", isOn: enabled)
            .accessibilityIdentifier(prefix + ".enabled").accessibilityLabel("Pass through unmatched requests")
        TextField("Real backend URL", text: Binding(get: { upstream.wrappedValue ?? "" }, set: { upstream.wrappedValue = $0.isEmpty ? nil : $0 }))
            .disabled(!enabled.wrappedValue)
            .accessibilityIdentifier(prefix + ".upstream").accessibilityLabel("Real backend URL")
        Toggle("Automatically save responses as mocks", isOn: capture)
            .disabled(!enabled.wrappedValue)
            .accessibilityIdentifier(prefix + ".capture").accessibilityLabel("Automatically save responses as mocks")
        Text("Capture saves complete text responses up to 5 MiB (traffic previews stay at 64 KiB) and removes credential headers. Bodies may contain private data. Once saved, a mock answers future matching calls.")
            .font(DSTypography.caption).foregroundStyle(DSColors.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(prefix + ".captureHelp")
    }
}

private enum BackendSettingsGeometry {
    static let width: CGFloat = 640

    static func height(forBackendCount count: Int, visibleScreenHeight: CGFloat) -> CGFloat {
        // Leave enough room above and below the sheet for macOS chrome. The Form owns scrolling;
        // the footer must stay on-screen even on the compact CI/display configuration.
        let screenCap = max(440, visibleScreenHeight - 200)
        return min(screenCap, 760, 520 + CGFloat(count) * 240)
    }
}
