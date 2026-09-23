import SwiftUI
import AppKit
import Domain
import DesignSystem

/// A single draft: validation and publication use the same atomic command as automation.
struct BackendSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ServerConfiguration
    @State private var selectedBackendID = ServerConfiguration.primaryID
    @State private var portText: [String: String] = [:]
    @State private var issue: FieldIssue?
    @State private var error: String?

    init(configuration: ServerConfiguration) {
        _draft = State(initialValue: configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("Server settings")
                    .font(DSTypography.title)
                    .foregroundStyle(DSColors.labelPrimary)
                Text("Configure local listeners and optional pass-through.")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
            }
            .padding(DSSpacing.lg)

            DSDivider(identifier: "backend.headerDivider")

            HStack(spacing: 0) {
                backendList
                    .frame(width: BackendSettingsGeometry.listWidth)
                Rectangle()
                    .fill(DSColors.separator)
                    .frame(width: DSStroke.seam)
                ScrollView {
                    selectedBackendDetails
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DSSpacing.xl)
                        .padding(.vertical, DSSpacing.lg)
                }
            }
            .frame(maxHeight: .infinity)

            DSDivider(identifier: "backend.footer")
            HStack(spacing: DSSpacing.md) {
                if needsRestart {
                    Label("Restart server to use listener changes", systemImage: "arrow.clockwise")
                        .font(DSTypography.label)
                        .foregroundStyle(DSColors.warningText)
                        .accessibilityIdentifier("backend.restartHelp")
                }
                if let error {
                    Text(error)
                        .font(DSTypography.label)
                        .foregroundStyle(DSColors.destructiveText)
                        .lineLimit(2)
                        .accessibilityIdentifier("backend.error")
                }
                Spacer(minLength: 0)
                DSButton("Cancel", variant: .ghost, size: .medium, identifier: "backend.cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("backend.cancel")
                .accessibilityLabel("Cancel settings changes")
                DSButton("Apply", variant: .primary, size: .medium, identifier: "backend.apply") {
                    apply()
                }
                .disabled(hasInvalidPorts)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("backend.apply")
                .accessibilityLabel("Apply server settings")
            }
            .padding(DSSpacing.lg)
        }
        .frame(width: DSSheetWidth.backendSettings,
               height: BackendSettingsGeometry.height(backend: draft.backend(id: selectedBackendID),
                                                      visibleScreenHeight: NSScreen.main?.visibleFrame.height ?? 900))
        .onChange(of: draft) { _, _ in clearIssue() }
        .onChange(of: portText) { _, _ in clearIssue() }
        .accessibilityElement(children: .contain)
    }

    private var backendList: some View {
        VStack(alignment: .leading, spacing: DSSpacing.smPlus) {
            Text("Listeners")
                .font(DSTypography.controlLabel)
                .foregroundStyle(DSColors.labelSecondary)
                .padding(.horizontal, DSSpacing.smPlus)
                .padding(.top, DSSpacing.smPlus)
            ScrollView {
                VStack(spacing: DSSpacing.xs) {
                    ForEach(draft.listeners) { backend in
                        backendRow(backend)
                    }
                }
                .padding(.horizontal, DSSpacing.smPlus)
            }
            HStack(spacing: DSSpacing.sm) {
                DSButton("Add", variant: .secondary, size: .small, identifier: "backend.add") {
                    addBackend()
                }
                .accessibilityIdentifier("backend.add")
                .accessibilityLabel("Add listener")
                DSButton("Remove", variant: .secondary, size: .small,
                         identifier: "backend.delete.\(selectedBackendID)") {
                    removeSelectedBackend()
                }
                .disabled(selectedBackendID == ServerConfiguration.primaryID)
                .accessibilityIdentifier("backend.delete.\(selectedBackendID)")
                .accessibilityLabel("Remove selected listener")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSSpacing.smPlus)
            .padding(.bottom, DSSpacing.smPlus)
        }
        .background(DSColors.surfaceElevated)
    }

    private func backendRow(_ backend: BackendConfiguration) -> some View {
        let isSelected = selectedBackendID == backend.id
        let prefix = backend.id == ServerConfiguration.primaryID ? "backend.primary" : "backend.\(backend.id)"
        let hasIssue = issue?.backendID == backend.id || validatedPort(for: prefix, fallback: backend.port) == nil
        return Button {
            selectedBackendID = backend.id
        } label: {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                HStack(spacing: DSSpacing.xs) {
                    Text(backend.name.isEmpty ? "Unnamed backend" : backend.name)
                        .font(isSelected ? DSTypography.bodyMedium : DSTypography.body)
                        .foregroundStyle(DSColors.labelPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if hasIssue {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: DSGlyph.inline))
                            .foregroundStyle(DSColors.destructiveText)
                            .accessibilityHidden(true)
                    }
                }
                Text(verbatim: backend.id == ServerConfiguration.primaryID
                     ? "Primary · port \(String(backend.port))" : "Port \(String(backend.port))")
                    .font(DSTypography.codeSmall)
                    .foregroundStyle(DSColors.labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.smPlus)
        }
        .buttonStyle(BackendRowButtonStyle(isSelected: isSelected))
        .accessibilityIdentifier("backend.select.\(backend.id)")
        .accessibilityLabel("\(backend.name), port \(String(backend.port))\(backend.id == ServerConfiguration.primaryID ? ", primary" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var selectedBackendDetails: some View {
        if selectedBackendID == ServerConfiguration.primaryID {
            fields(name: $draft.primaryName, port: $draft.port, upstream: $draft.upstreamURL,
                   enabled: $draft.passthroughEnabled, capture: $draft.captureResponses,
                   prefix: "backend.primary", backendID: ServerConfiguration.primaryID)
        } else if let index = draft.backends.firstIndex(where: { $0.id == selectedBackendID }) {
            fields(name: $draft.backends[index].name, port: $draft.backends[index].port,
                   upstream: $draft.backends[index].upstreamURL,
                   enabled: $draft.backends[index].passthroughEnabled,
                   capture: $draft.backends[index].captureResponses,
                   prefix: "backend.\(selectedBackendID)", backendID: selectedBackendID)
        }
    }

    @ViewBuilder
    private func fields(name: Binding<String>, port: Binding<Int>, upstream: Binding<String?>,
                        enabled: Binding<Bool>, capture: Binding<Bool>, prefix: String, backendID: UUID) -> some View {
        let validPort = validatedPort(for: prefix, fallback: port.wrappedValue)
        let pendingRestart = appState.serverState.runningPort != nil
            && appState.server.boundConfiguration?.backend(id: backendID)?.port != validPort
        VStack(alignment: .leading, spacing: DSSpacing.xl) {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                sectionHeading("Local listener", detail: "Your app connects to this address.")
                HStack(alignment: .top, spacing: DSSpacing.md) {
                    DSTextField("Name", text: name,
                                validation: fieldIssue(backendID, .name), identifier: prefix + ".name")
                        .accessibilityIdentifier(prefix + ".name")
                    DSTextField("Port", text: Binding(get: {
                        portText[prefix] ?? String(port.wrappedValue)
                    }, set: {
                        portText[prefix] = $0
                        if let value = Int($0), (1...65535).contains(value) { port.wrappedValue = value }
                    }), validation: validPort == nil ? "Use 1–65535" : fieldIssue(backendID, .port),
                        identifier: prefix + ".port")
                        .frame(width: DSFormMetrics.portFieldWidth)
                        .accessibilityIdentifier(prefix + ".port")
                }
                HStack(spacing: DSSpacing.sm) {
                    Text(verbatim: validPort.map { "http://localhost:\(String($0))" } ?? "Enter a valid local port")
                        .font(DSTypography.code)
                        .foregroundStyle(DSColors.labelPrimary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(prefix + ".localURL")
                    Spacer(minLength: 0)
                    DSButton("Copy URL", variant: .secondary, size: .small, identifier: prefix + ".copy") {
                        guard let validPort else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("http://localhost:\(validPort)", forType: .string)
                    }
                    .disabled(validPort == nil)
                    .accessibilityIdentifier(prefix + ".copy")
                    .accessibilityLabel("Copy local URL")
                }
                if pendingRestart {
                    Text("Available after server restart")
                        .font(DSTypography.label)
                        .foregroundStyle(DSColors.warningText)
                        .accessibilityIdentifier(prefix + ".pendingRestart")
                }
            }
            DSDivider(identifier: prefix + ".sectionDivider")
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                sectionHeading("Pass-through", detail: "Forward calls that do not match a mock.")
                settingsToggle("Enable pass-through", isOn: enabled,
                               identifier: prefix + ".enabled")
                if enabled.wrappedValue {
                    DSTextField("Real backend URL", text: Binding(get: {
                        upstream.wrappedValue ?? ""
                    }, set: {
                        upstream.wrappedValue = $0.isEmpty ? nil : $0
                    }), placeholder: "https://api.example.com",
                        validation: fieldIssue(backendID, .upstream), identifier: prefix + ".upstream")
                        .accessibilityIdentifier(prefix + ".upstream")
                        .accessibilityLabel("Real backend URL")
                    settingsToggle("Save responses as mocks", isOn: capture,
                                   identifier: prefix + ".capture")
                    if capture.wrappedValue {
                        Text("Saves text responses up to 5 MiB. Traffic previews show 64 KiB. Credential headers are removed; review bodies for private data.")
                            .font(DSTypography.label)
                            .foregroundStyle(DSColors.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(prefix + ".captureHelp")
                    }
                }
            }
        }
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(title).font(DSTypography.subheading).foregroundStyle(DSColors.labelPrimary)
            Text(detail).font(DSTypography.label).foregroundStyle(DSColors.labelSecondary)
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>, identifier: String) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .font(DSTypography.body)
        .foregroundStyle(DSColors.labelPrimary)
        .tint(DSColors.accent)
        .frame(maxWidth: .infinity, minHeight: DSControlHeight.prominent)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }

    private var needsRestart: Bool {
        appState.serverState.runningPort != nil
            && appState.server.boundConfiguration.map { !$0.hasSameListeners(as: draft) } == true
    }

    private func addBackend() {
        let used = Set(draft.listeners.map(\.port))
        let port = (8081...65535).first { !used.contains($0) } ?? 8081
        let backend = BackendConfiguration(name: "New backend", port: port)
        draft.backends.append(backend)
        selectedBackendID = backend.id
    }

    private func removeSelectedBackend() {
        guard selectedBackendID != ServerConfiguration.primaryID else { return }
        draft.backends.removeAll { $0.id == selectedBackendID }
        selectedBackendID = ServerConfiguration.primaryID
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

    private func fieldIssue(_ id: UUID, _ field: FieldIssue.Field) -> String? {
        guard issue?.backendID == id, issue?.field == field else { return nil }
        return issue?.message
    }

    private func clearIssue() {
        issue = nil
        error = nil
    }

    private func apply() {
        if let firstIssue = firstIssue() {
            selectedBackendID = firstIssue.backendID
            issue = firstIssue
            return
        }
        if appState.applyServerConfiguration(draft) { dismiss() }
        else { error = appState.lastCommandError }
    }

    /// Immediate form guidance; Domain still validates the complete configuration on Apply.
    private func firstIssue() -> FieldIssue? {
        var seenPorts = Set<Int>()
        let ports = Set(draft.listeners.map(\.port))
        for backend in draft.listeners {
            if backend.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return FieldIssue(backendID: backend.id, field: .name, message: "Enter a backend name")
            }
            if !seenPorts.insert(backend.port).inserted {
                return FieldIssue(backendID: backend.id, field: .port, message: "This port is used by another backend")
            }
            if backend.passthroughEnabled && backend.upstreamURL?.isEmpty != false {
                return FieldIssue(backendID: backend.id, field: .upstream, message: "Enter a real backend URL")
            }
            if let value = backend.upstreamURL, !value.isEmpty {
                guard let parts = URLComponents(string: value),
                      let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      let host = parts.host, !host.isEmpty,
                      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                      !ports.contains(parts.port ?? (scheme == "https" ? 443 : 80))
                        || !["127.0.0.1", "localhost", "::1"].contains(
                            host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) else {
                    return FieldIssue(backendID: backend.id, field: .upstream,
                                      message: "Enter an HTTP or HTTPS base URL outside these local listeners")
                }
            }
        }
        return nil
    }
}

private struct FieldIssue {
    enum Field { case name, port, upstream }
    let backendID: UUID
    let field: Field
    let message: String
}

private enum BackendSettingsGeometry {
    static let listWidth: CGFloat = 200

    static func height(backend: BackendConfiguration?, visibleScreenHeight: CGFloat) -> CGFloat {
        let contentHeight: CGFloat
        if backend?.passthroughEnabled == true {
            contentHeight = backend?.captureResponses == true ? 560 : 520
        } else {
            contentHeight = 460
        }
        return min(contentHeight, max(440, visibleScreenHeight - DSFormMetrics.screenVerticalAllowance))
    }
}

/// A listener selection stays blue; hover is a quiet neutral surface, so the two states cannot
/// look like two selected listeners when the pointer remains over the previous row.
private struct BackendRowButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, isSelected: isSelected)
    }

    private struct Row: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                        .fill(isSelected || configuration.isPressed ? DSColors.accentMuted
                              : isHovered ? DSColors.tertiary : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: DSCornerRadius.sm))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
                .animation(.easeOut(duration: DSAnimation.micro), value: configuration.isPressed)
        }
    }
}
