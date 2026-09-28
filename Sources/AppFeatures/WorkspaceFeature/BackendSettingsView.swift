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
            VStack(alignment: .leading, spacing: 3) {
                Text("Server settings")
                    .font(DSTypography.headline)
                    .foregroundStyle(DSColors.labelPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(appState.currentProject?.name ?? "Local ports and pass-through")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DSSpacing.xl)
            .padding(.top, DSSpacing.xl)
            .padding(.bottom, DSSpacing.lg)

            DSDivider(identifier: "backend.headerDivider")

            HStack(spacing: 0) {
                backendList
                    .frame(width: BackendSettingsGeometry.listWidth)
                DSDivider(axis: .vertical, identifier: "backend.listDivider")
                ScrollView {
                    selectedBackendDetails
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DSSpacing.xl)
                        .padding(.vertical, DSSpacing.lg)
                }
            }
            .frame(maxHeight: .infinity)

            DSDivider(identifier: "backend.footer")
            footer
        }
        .frame(width: DSSheetWidth.wide,
               height: BackendSettingsGeometry.height(backend: draft.backend(id: selectedBackendID),
                                                      visibleScreenHeight: NSScreen.main?.visibleFrame.height ?? 900))
        .background(DSColors.sheet)
        .onChange(of: draft) { _, _ in clearIssue() }
        .onChange(of: portText) { _, _ in clearIssue() }
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack(spacing: DSSpacing.sm) {
            if needsRestart {
                Label("Restart the server to use port changes", systemImage: "arrow.clockwise")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.warning)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: DSControlHeight.regular)
                    .background(Capsule().fill(DSColors.warningBackground))
                    .accessibilityIdentifier("backend.restartHelp")
            }
            if let error {
                Text(error)
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.error)
                    .lineLimit(2)
                    .accessibilityIdentifier("backend.error")
            }
            Spacer(minLength: 0)
            DSButton("Cancel", variant: .secondary, size: .large, identifier: "backend.cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("backend.cancel")
            .accessibilityLabel("Cancel settings changes")
            DSButton("Apply", variant: .primary, size: .large, identifier: "backend.apply") {
                apply()
            }
            .disabled(hasInvalidPorts)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("backend.apply")
            .accessibilityLabel("Apply server settings")
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.vertical, 14)
    }

    private var backendList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ports")
                .font(DSTypography.captionSemibold)
                .foregroundStyle(DSColors.labelTertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(spacing: DSSpacing.xxs) {
                    ForEach(draft.listeners) { backend in
                        backendRow(backend)
                    }
                }
            }
            addRemoveControl
                .padding(.top, DSSpacing.sm)
        }
        .padding(.top, DSSpacing.md)
        .padding([.horizontal, .bottom], DSSpacing.sm)
        .background(DSColors.window)
    }

    /// The macOS add and remove pair under a source list.
    private var addRemoveControl: some View {
        HStack(spacing: 0) {
            Button {
                addBackend()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: DSGlyph.field, weight: .medium))
                    .frame(width: DSControlHeight.large, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DSColors.labelPrimary)
            .help("Add port")
            .accessibilityIdentifier("backend.add")
            .accessibilityLabel("Add port")

            Rectangle()
                .fill(DSColors.fieldBorder)
                .frame(width: DSStroke.hairline, height: 22)
                .accessibilityHidden(true)

            Button {
                removeSelectedBackend()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: DSGlyph.field, weight: .medium))
                    .frame(width: DSControlHeight.large, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canRemoveSelected ? DSColors.labelPrimary : DSColors.labelTertiary)
            .disabled(!canRemoveSelected)
            .help("Remove port")
            .accessibilityIdentifier("backend.delete.\(selectedBackendID)")
            .accessibilityLabel("Remove selected port")
        }
        .background(DSColors.field)
        .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.field))
        .overlay {
            RoundedRectangle(cornerRadius: DSCornerRadius.field)
                .strokeBorder(DSColors.fieldBorder, lineWidth: DSStroke.hairline)
                .allowsHitTesting(false)
        }
    }

    private var canRemoveSelected: Bool { selectedBackendID != ServerConfiguration.primaryID }

    private func backendRow(_ backend: BackendConfiguration) -> some View {
        let isSelected = selectedBackendID == backend.id
        let isPrimary = backend.id == ServerConfiguration.primaryID
        let prefix = isPrimary ? "backend.primary" : "backend.\(backend.id)"
        let port = validatedPort(for: prefix, fallback: backend.port)
        let hasIssue = issue?.backendID == backend.id || port == nil
        let restartPending = appState.serverState.runningPort != nil
            && appState.server.boundConfiguration?.backend(id: backend.id)?.port != port
        var label = "\(backend.name), port \(String(backend.port))"
        if isPrimary { label += ", primary" }
        if restartPending && !hasIssue { label += ", needs a restart" }
        return Button {
            selectedBackendID = backend.id
        } label: {
            HStack(spacing: DSSpacing.sm) {
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(backend.name.isEmpty ? "Unnamed port" : backend.name)
                        .font(isSelected ? DSTypography.bodyMedium : DSTypography.body)
                        .foregroundStyle(isSelected ? Color.white : DSColors.labelPrimary)
                        .lineLimit(1)
                    Text(verbatim: isPrimary ? ":\(String(backend.port)) · main" : ":\(String(backend.port))")
                        .font(DSTypography.caption.monospaced())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : DSColors.labelSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if hasIssue {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: DSGlyph.field))
                        .foregroundStyle(isSelected ? Color.white : DSColors.error)
                        .accessibilityHidden(true)
                } else if restartPending {
                    Circle()
                        .fill(DSColors.warning)
                        .frame(width: 7, height: 7)
                        .help("Needs a restart")
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: DSFormMetrics.groupRowHeight, alignment: .leading)
            .padding(.horizontal, 10)
        }
        .buttonStyle(BackendRowButtonStyle(isSelected: isSelected))
        .accessibilityIdentifier("backend.select.\(backend.id)")
        .accessibilityLabel(label)
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
        VStack(alignment: .leading, spacing: 18) {
            DSFormSection("Port", identifier: prefix + ".portSection") {
                DSFormGroupRow("Name") {
                    DSTextField("Name", text: name,
                                validation: fieldIssue(backendID, .name),
                                controlWidth: 220,
                                inputIdentifier: prefix + ".name",
                                labelPlacement: .hidden,
                                height: DSControlHeight.regular,
                                identifier: prefix + ".name")
                }
                DSDivider()
                DSFormGroupRow("Port") {
                    DSTextField("Port", text: Binding(get: {
                        portText[prefix] ?? String(port.wrappedValue)
                    }, set: {
                        portText[prefix] = $0
                        if let value = Int($0), (1...65535).contains(value) { port.wrappedValue = value }
                    }), validation: validPort == nil ? "Use 1–65535" : fieldIssue(backendID, .port),
                        controlWidth: DSFormMetrics.portFieldWidth,
                        inputIdentifier: prefix + ".port",
                        monospaced: true,
                        labelPlacement: .hidden,
                        height: DSControlHeight.regular,
                        identifier: prefix + ".port")
                }
                if pendingRestart {
                    Text("Available after server restart")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.warning)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.bottom, DSSpacing.sm)
                        .accessibilityIdentifier(prefix + ".pendingRestart")
                }
                DSDivider()
                DSFormGroupRow("Your app connects to") {
                    Text(verbatim: validPort.map { "http://localhost:\(String($0))" } ?? "Enter a valid local port")
                        .font(DSTypography.code)
                        .foregroundStyle(DSColors.labelSecondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(prefix + ".localURL")
                    DSButton("Copy", variant: .secondary, size: .small, identifier: prefix + ".copy") {
                        guard let validPort else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("http://localhost:\(validPort)", forType: .string)
                    }
                    .disabled(validPort == nil)
                    .accessibilityIdentifier(prefix + ".copy")
                    .accessibilityLabel("Copy local URL")
                }
            }

            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                DSFormSection("Upstream", identifier: prefix + ".upstreamSection") {
                    DSFormToggle("Forward unmatched requests",
                                 description: "Requests with no endpoint go to your real server.",
                                 isOn: enabled, identifier: prefix + ".enabled")
                    if enabled.wrappedValue {
                        DSDivider()
                        DSFormGroupRow("Upstream URL") {
                            DSTextField("Upstream URL", text: Binding(get: {
                                upstream.wrappedValue ?? ""
                            }, set: {
                                upstream.wrappedValue = $0.isEmpty ? nil : $0
                            }), placeholder: "https://api.example.com",
                                validation: fieldIssue(backendID, .upstream),
                                validationIdentifier: prefix + ".upstreamError",
                                controlWidth: 260,
                                inputIdentifier: prefix + ".upstream",
                                monospaced: true,
                                labelPlacement: .hidden,
                                height: DSControlHeight.regular,
                                identifier: prefix + ".upstream")
                        }
                        DSDivider()
                        DSFormToggle("Save forwarded responses as scenarios",
                                     description: "Credential headers are removed. Check bodies for private data.",
                                     isOn: capture, identifier: prefix + ".capture")
                    }
                }
                if enabled.wrappedValue && capture.wrappedValue {
                    Text("Saves text responses up to 5 MiB. Traffic previews show 64 KiB.")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DSSpacing.xs)
                        .accessibilityIdentifier(prefix + ".captureHelp")
                }
            }
        }
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
                        || !EndpointValidator.isLoopbackHost(host) else {
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
    static let listWidth: CGFloat = 208

    static func height(backend: BackendConfiguration?, visibleScreenHeight: CGFloat) -> CGFloat {
        let contentHeight: CGFloat
        if backend?.passthroughEnabled == true {
            contentHeight = backend?.captureResponses == true ? 580 : 520
        } else {
            contentHeight = 460
        }
        return min(contentHeight, max(440, visibleScreenHeight - DSFormMetrics.screenVerticalAllowance))
    }
}

/// The selected port is an accent fill with white text; hover is a quiet neutral wash, so the two
/// never read as two selections.
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
                    RoundedRectangle(cornerRadius: DSCornerRadius.segment)
                        .fill(isSelected ? DSColors.accent
                              : configuration.isPressed ? DSColors.selectionInactive
                              : isHovered ? DSColors.hover : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: DSCornerRadius.segment))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: DSAnimation.fast), value: isHovered)
                .animation(.easeOut(duration: DSAnimation.fast), value: configuration.isPressed)
        }
    }
}
