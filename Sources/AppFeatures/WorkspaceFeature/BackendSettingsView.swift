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
                    Text("Server settings")
                        .font(DSTypography.title)
                        .foregroundStyle(DSColors.labelPrimary)
                    Spacer()
                    // Keep the creation action outside the scrolling content. On a short display,
                    // a click on its last row can be consumed while dismissing field focus.
                    DSButton("Add backend", variant: .secondary, size: .small, identifier: "backend.add") {
                        addBackend()
                    }
                    .accessibilityIdentifier("backend.add")
                    .accessibilityLabel("Add backend")
                }
                Text("Point your app to a local URL. Mimic serves configured mocks; pass-through can forward unmatched requests to a real backend.")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.md) {
                        DSFormSection("Primary backend", identifier: "backend.primary") {
                            fields(name: $draft.primaryName, port: $draft.port, upstream: $draft.upstreamURL,
                                   enabled: $draft.passthroughEnabled, capture: $draft.captureResponses,
                                   prefix: "backend.primary", backendID: ServerConfiguration.primaryID)
                        }
                        ForEach($draft.backends) { $backend in
                            DSFormSection(backend.name.isEmpty ? "New backend" : backend.name,
                                          identifier: "backend.\(backend.id)") {
                                fields(name: $backend.name, port: $backend.port, upstream: $backend.upstreamURL,
                                       enabled: $backend.passthroughEnabled, capture: $backend.captureResponses,
                                       prefix: "backend.\(backend.id)", backendID: backend.id)
                                DSButton("Remove backend", variant: .destructive, size: .small,
                                         identifier: "backend.delete.\(backend.id)") {
                                    draft.backends.removeAll { $0.id == backend.id }
                                }
                                .accessibilityIdentifier("backend.delete.\(backend.id)")
                                .accessibilityLabel("Remove \(backend.name)")
                            }
                            .id(backend.id)
                        }
                    }
                    .padding(.vertical, DSSpacing.xxs)
                }
                .onChange(of: newestBackendID) { _, id in
                    guard let id else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        scrollProxy.scrollTo(id, anchor: .top)
                    }
                }
            }
            if let error {
                Text(error).font(DSTypography.label).foregroundStyle(DSColors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("backend.error")
            }
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                DSDivider(identifier: "backend.footer")
                Text("Pass-through changes apply immediately. Adding, removing, or changing a local port requires a server restart.")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("backend.restartHelp")
                HStack(spacing: DSSpacing.md) {
                    Spacer(minLength: 0)
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
                    .disabled(hasInvalidPorts)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("backend.apply")
                    .accessibilityLabel("Apply server settings")
                }
            }
        }
        .padding(DSSpacing.lg)
        // One backend should not leave a large empty scroll region. Grow the sheet as listeners
        // are added, then let the content scroll once the window reaches a practical height.
        .frame(
            width: DSSheetWidth.wide,
            height: BackendSettingsGeometry.height(
                forBackendCount: draft.backends.count,
                visibleScreenHeight: NSScreen.main?.visibleFrame.height ?? 900
            )
        )
        // Dynamic sections keep identifiers on their individual fields.
        .accessibilityElement(children: .contain)
    }

    private func addBackend() {
        let used = Set(draft.listeners.map(\.port))
        let port = (8081...65535).first { !used.contains($0) } ?? 8081
        let backend = BackendConfiguration(name: "New backend", port: port)
        draft.backends.append(backend)
        newestBackendID = backend.id
    }

    private var hasInvalidPorts: Bool {
        draft.listeners.contains { backend in
            let prefix = backend.id == ServerConfiguration.primaryID ? "backend.primary" : "backend.\(backend.id)"
            return validatedPort(for: prefix, fallback: backend.port) == nil
        }
    }

    private func validatedPort(for prefix: String, fallback: Int) -> Int? {
        let value = portText[prefix] ?? String(fallback)
        guard let port = Int(value), (1...65535).contains(port) else { return nil }
        return port
    }

    @ViewBuilder
    private func fields(name: Binding<String>, port: Binding<Int>, upstream: Binding<String?>,
                        enabled: Binding<Bool>, capture: Binding<Bool>, prefix: String, backendID: UUID) -> some View {
        let validPort = validatedPort(for: prefix, fallback: port.wrappedValue)
        let pendingRestart = appState.serverState.runningPort != nil
            && appState.server.boundConfiguration?.backend(id: backendID)?.port != validPort
        HStack(alignment: .top, spacing: DSSpacing.md) {
            DSTextField("Name", text: name, identifier: prefix + ".name")
                .accessibilityIdentifier(prefix + ".name")
            DSTextField("Local port", text: Binding(get: {
                portText[prefix] ?? String(port.wrappedValue)
            }, set: {
                portText[prefix] = $0
                if let value = Int($0), (1...65535).contains(value) { port.wrappedValue = value }
            }), validation: validPort == nil ? "Use 1–65535" : nil,
                identifier: prefix + ".port")
                .frame(width: DSFormMetrics.portFieldWidth)
                .accessibilityIdentifier(prefix + ".port")
        }
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(pendingRestart ? "Configured URL" : "App connects to")
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelSecondary)
            HStack(spacing: DSSpacing.md) {
                Text(verbatim: validPort.map { "http://localhost:\(String($0))" } ?? "Enter a valid local port")
                    .font(DSTypography.code)
                    .foregroundStyle(DSColors.labelPrimary)
                    .textSelection(.enabled)
                Spacer(minLength: DSSpacing.sm)
                DSButton("Copy URL", variant: .secondary, size: .small, identifier: prefix + ".copy") {
                    guard let validPort else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("http://localhost:\(validPort)", forType: .string)
                }
                .disabled(validPort == nil)
                .accessibilityIdentifier(prefix + ".copy").accessibilityLabel("Copy local URL")
            }
            .padding(.horizontal, DSSpacing.smPlus)
            .frame(height: DSBarHeight.controlRow)
            .background(DSColors.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.lg))
            if pendingRestart {
                Text("Available after server restart")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.warningText)
                    .accessibilityIdentifier(prefix + ".pendingRestart")
            }
        }
        DSFormToggle("Pass through unmatched requests", isOn: enabled, identifier: prefix + ".enabled")
        DSTextField("Real backend URL", text: Binding(get: {
            upstream.wrappedValue ?? ""
        }, set: {
            upstream.wrappedValue = $0.isEmpty ? nil : $0
        }), placeholder: "https://api.example.com", identifier: prefix + ".upstream")
            .disabled(!enabled.wrappedValue)
            .accessibilityIdentifier(prefix + ".upstream").accessibilityLabel("Real backend URL")
        DSFormToggle("Automatically save responses as mocks", isOn: capture, identifier: prefix + ".capture")
            .disabled(!enabled.wrappedValue)
        Text("Capture saves complete text responses up to 5 MiB (traffic previews stay at 64 KiB) and removes credential headers. Bodies may contain private data. Once saved, a mock answers future matching calls.")
            .font(DSTypography.label).foregroundStyle(DSColors.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(prefix + ".captureHelp")
    }
}

private enum BackendSettingsGeometry {
    static func height(forBackendCount count: Int, visibleScreenHeight: CGFloat) -> CGFloat {
        // Leave enough room above and below the sheet for macOS chrome. The scroll view owns overflow;
        // the footer must stay on-screen even on the compact CI/display configuration.
        let screenCap = max(440, visibleScreenHeight - 200)
        return min(screenCap, 760, 520 + CGFloat(count) * 300)
    }
}
