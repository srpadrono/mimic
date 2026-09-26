import AppKit
import SwiftUI
import Domain
import DesignSystem

/// A stable two-line summary; every address is copied from the same server-details popover.
struct ServerStatusWell: View {
    @Environment(\.isEnabled) private var isEnabled
    let serverState: ServerState
    let projectName: String?
    let requestCount: Int
    let unmatchedCount: Int
    var compact = false
    var iconOnly = false
    var configuration: ServerConfiguration?
    var boundConfiguration: ServerConfiguration?
    var onShowUnmatched: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowTraffic: (() -> Void)?

    @State private var showingDetails = false
    @State private var isHovered = false
    @State private var copiedPort: Int?
    @State private var copyResetTask: Task<Void, Never>?

    private var isRunning: Bool { serverState.runningPort != nil }
    private var restartRequired: Bool {
        Self.requiresRestart(serverState: serverState, configuration: configuration, boundConfiguration: boundConfiguration)
    }
    private var backends: [BackendConfiguration] {
        Self.displayedBackends(serverState: serverState, configuration: configuration, boundConfiguration: boundConfiguration)
    }
    private var title: String {
        Self.summaryTitle(serverState: serverState, configuration: configuration,
                          boundConfiguration: boundConfiguration, compact: compact)
    }
    private var subtitle: String {
        Self.summarySubtitle(serverState: serverState, restartRequired: restartRequired,
                             requestCount: requestCount, unmatchedCount: unmatchedCount, compact: compact)
    }
    var statusColor: Color {
        if restartRequired { return DSColors.warningText }
        switch serverState {
        case .running: return DSColors.successText
        case .error: return DSColors.destructiveText
        case .stopped, .starting, .stopping: return DSColors.labelSecondary
        }
    }
    private var canShowDetails: Bool { isEnabled && (configuration != nil || isRunning) }
    private var detailsDescription: String {
        let subject = projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = subject.flatMap { $0.isEmpty ? nil : $0 } ?? "No project"
        let addresses = backends.map(\.localURL).joined(separator: ", ")
        let ports = configuration.map {
            Self.backendSummary(configuration: $0, boundConfiguration: boundConfiguration, isRunning: isRunning)
        } ?? ""
        let unmatched = unmatchedCount > 0 ? " \(Self.unmatchedLabel(unmatchedCount, actionable: false))." : ""
        return "\(name), \(Self.stateDescription(serverState)). \(addresses). \(ports) \(Self.requestCountLabel(requestCount)).\(unmatched) Show server details."
    }

    var body: some View {
        Button { showingDetails.toggle() } label: {
            Group {
                if iconOnly {
                    HStack(spacing: DSSpacing.xxs) {
                        Image(systemName: restartRequired ? "exclamationmark.arrow.circlepath" : "server.rack")
                            .font(.system(size: DSGlyph.controlProminent, weight: .regular))
                            .foregroundStyle(statusColor)
                            .accessibilityHidden(true)
                        Image(systemName: "chevron.down")
                            .font(.system(size: DSGlyph.indicator, weight: .semibold))
                            .foregroundStyle(DSColors.labelSecondary)
                            .accessibilityHidden(true)
                    }
                    .frame(width: DSToolbarGeometry.iconStatusWidth, height: DSToolbarGeometry.height)
                } else {
                    VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                        HStack(spacing: DSSpacing.sm) {
                            Text(verbatim: title)
                                .font(DSTypography.bodyBold)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: DSGlyph.indicator, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(isHovered ? DSColors.accentText : DSColors.labelPrimary)
                        Text(verbatim: subtitle)
                            .font(DSTypography.label)
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: DSToolbarGeometry.height)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canShowDetails)
        .onHover { isHovered = $0 && canShowDetails }
        .onChange(of: canShowDetails) { _, enabled in
            if !enabled { isHovered = false }
        }
        .help(detailsDescription)
        .accessibilityIdentifier("serverStatusWell.url")
        .accessibilityLabel("Server details, \(Self.stateDescription(serverState))")
        .accessibilityValue(detailsDescription)
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) { serverDetails }
        .onChange(of: serverState) { _, _ in copiedPort = nil }
        .onDisappear { copyResetTask?.cancel() }
    }

    private var serverDetails: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Local servers")
                .font(DSTypography.bodyBold)
            Text(isRunning ? "Listening now" : "Configured addresses")
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelSecondary)

            // A long backend list scrolls; the settings and traffic actions remain reachable.
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    ForEach(backends) { backend in
                        backendRow(backend)
                        Divider()
                    }
                    if restartRequired, let configuration {
                        Label("Configured — restart required", systemImage: "exclamationmark.arrow.circlepath")
                            .font(DSTypography.label)
                            .foregroundStyle(DSColors.warningText)
                        ForEach(configuration.listeners) { backend in
                            Text(verbatim: "\(backend.name): \(backend.port)")
                                .font(DSTypography.label)
                                .accessibilityIdentifier("serverStatusWell.configuredPort.\(backend.port)")
                        }
                    }
                }
            }
            .frame(maxHeight: DSToolbarGeometry.detailsListHeight)
            .fixedSize(horizontal: false, vertical: true)

            if case .error(let message) = serverState {
                Text(verbatim: message)
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.destructive)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("serverStatusWell.error")
            }

            HStack {
                Text(Self.requestCountLabel(requestCount))
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                    .accessibilityIdentifier("serverStatusWell.requestCount")
                Spacer(minLength: DSSpacing.sm)
                if unmatchedCount > 0, let onShowUnmatched {
                    Button {
                        showingDetails = false
                        onShowUnmatched()
                    } label: {
                        Label("\(unmatchedCount) unmatched", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DSColors.warningText)
                    .accessibilityIdentifier("serverStatusWell.unmatched")
                    .accessibilityLabel(Self.unmatchedLabel(unmatchedCount, actionable: true))
                    .help("Show requests no endpoint or journey answered")
                }
            }
            Divider()
            HStack {
                if let onShowSettings {
                    Button("Server settings…") {
                        showingDetails = false
                        onShowSettings()
                    }
                    .accessibilityIdentifier("serverStatusWell.settings")
                    .accessibilityLabel("Server settings")
                }
                Spacer(minLength: DSSpacing.md)
                if let onShowTraffic {
                    Button("View traffic") {
                        showingDetails = false
                        onShowTraffic()
                    }
                    .accessibilityIdentifier("serverStatusWell.traffic")
                    .accessibilityLabel("View traffic")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(DSSpacing.lg)
        .frame(width: DSToolbarGeometry.detailsWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serverStatusWell.portList")
    }

    private func backendRow(_ backend: BackendConfiguration) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack {
                Text(verbatim: backend.name)
                    .font(DSTypography.bodyMedium)
                Spacer(minLength: DSSpacing.md)
                Button { copyURL(for: backend) } label: {
                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: copiedPort == backend.port ? "checkmark" : "doc.on.doc")
                        Text(copiedPort == backend.port ? "Copied" : "Copy URL")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(DSTypography.label)
                    .frame(minWidth: DSToolbarGeometry.copyButtonWidth, alignment: .trailing)
                }
                .buttonStyle(.borderless)
                .layoutPriority(1)
                .disabled(!isRunning)
                .accessibilityIdentifier("serverStatusWell.copyPort.\(backend.port)")
                .accessibilityLabel("Copy \(backend.name) URL, port \(String(backend.port))")
                .accessibilityValue(copiedPort == backend.port ? "Copied" : "")
                .help("Copy \(backend.localURL)")
            }
            Text(verbatim: backend.localURL)
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelSecondary)
                .textSelection(.enabled)
                .accessibilityIdentifier(isRunning
                    ? "serverStatusWell.listeningPort.\(backend.port)"
                    : "serverStatusWell.configuredPort.\(backend.port)")
            Text(isRunning ? "Running" : Self.shortState(serverState))
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelSecondary)
        }
    }

    private func copyURL(for backend: BackendConfiguration) {
        guard isRunning, backends.contains(where: { $0.id == backend.id && $0.port == backend.port }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(backend.localURL, forType: .string)
        copiedPort = backend.port
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            copiedPort = nil
        }
    }

    // MARK: - Presentation rules

    /// Only the runtime snapshot may advertise active listeners. Names may change without a restart.
    nonisolated static func displayedBackends(
        serverState: ServerState, configuration: ServerConfiguration?, boundConfiguration: ServerConfiguration?
    ) -> [BackendConfiguration] {
        guard let port = serverState.runningPort else { return configuration?.listeners ?? [] }
        let listening = boundConfiguration?.listeners
            ?? [.init(id: ServerConfiguration.primaryID, name: configuration?.primaryName ?? "Primary", port: port)]
        return listening.map { backend in
            var result = backend
            result.name = configuration?.backend(id: backend.id)?.name ?? backend.name
            return result
        }
    }

    nonisolated static func requiresRestart(
        serverState: ServerState, configuration: ServerConfiguration?, boundConfiguration: ServerConfiguration?
    ) -> Bool {
        guard serverState.runningPort != nil, let configuration, let boundConfiguration else { return false }
        return !configuration.hasSameListeners(as: boundConfiguration)
    }

    nonisolated static func summaryTitle(
        serverState: ServerState, configuration: ServerConfiguration?, boundConfiguration: ServerConfiguration?, compact: Bool
    ) -> String {
        let listeners = displayedBackends(serverState: serverState, configuration: configuration, boundConfiguration: boundConfiguration)
        guard let primary = listeners.first else { return "No project" }
        if listeners.count > 1 { return compact ? "\(listeners.count) ports" : "localhost · \(listeners.count) ports" }
        return compact ? "Port \(primary.port)" : "localhost:\(primary.port)"
    }

    nonisolated static func summarySubtitle(
        serverState: ServerState, restartRequired: Bool, requestCount: Int, unmatchedCount: Int, compact: Bool
    ) -> String {
        if case .error = serverState { return "Server error" }
        if restartRequired { return "Restart required" }
        let state = shortState(serverState)
        if unmatchedCount > 0 { return "\(state) · \(unmatchedCount) unmatched" }
        if !compact, serverState.runningPort != nil {
            return "\(state) · \(requestCount) \(requestCount == 1 ? "request" : "requests")"
        }
        return state
    }

    nonisolated static func shortState(_ state: ServerState) -> String {
        switch state {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case .error: "Server error"
        }
    }

    nonisolated static func stateDescription(_ state: ServerState) -> String {
        if case .error(let message) = state { return "server error: \(message)" }
        return "server \(shortState(state).replacingOccurrences(of: "…", with: "").lowercased())"
    }

    nonisolated static func backendSummary(
        configuration: ServerConfiguration, boundConfiguration: ServerConfiguration?, isRunning: Bool
    ) -> String {
        let configured = configuration.listeners.map { "\($0.name): \($0.port)" }.joined(separator: ", ")
        if isRunning, let boundConfiguration {
            let backends = displayedBackends(serverState: .running(port: boundConfiguration.port), configuration: configuration, boundConfiguration: boundConfiguration)
            let listening = backends.map { "\($0.name): \($0.port)" }.joined(separator: ", ")
            if !boundConfiguration.hasSameListeners(as: configuration) {
                return "Listening on \(listening). Configured ports: \(configured). Restart required."
            }
            return "\(backends.count) \(backends.count == 1 ? "port" : "ports") listening: \(listening)."
        }
        return "\(configuration.listeners.count) \(configuration.listeners.count == 1 ? "port" : "ports") configured: \(configured). Server is not running."
    }

    nonisolated static func requestCountLabel(_ count: Int) -> String {
        count == 0 ? "No requests logged" : "\(count) \(count == 1 ? "request" : "requests") logged"
    }

    nonisolated static func unmatchedLabel(_ count: Int, actionable: Bool) -> String {
        let subject = count == 1 ? "1 unmatched request" : "\(count) unmatched requests"
        return actionable ? "\(subject), show \(count == 1 ? "it" : "them")" : subject
    }
}
