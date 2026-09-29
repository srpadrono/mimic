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
    /// Narrow toolbars keep the state word and drop the request counts.
    var compact = false
    var configuration: ServerConfiguration?
    var boundConfiguration: ServerConfiguration?
    /// When the server started serving; the popover says "since 21:32" beside Running.
    var runningSince: Date?
    var onShowUnmatched: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onToggleServer: (() -> Void)?

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
        if restartRequired { return DSColors.warning }
        switch serverState {
        case .running: return DSColors.success
        case .error: return DSColors.error
        case .stopped, .starting, .stopping: return DSColors.labelTertiary
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
            summary
                .padding(.horizontal, compact ? Self.compactInset : Self.inset)
                .frame(height: DSControlHeight.prominent)
                .contentShape(.capsule)
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

    /// The capsule's inner inset and the gap between its parts, as the design draws them.
    private static let inset = DSSpacing.md + DSSpacing.xxs
    private static let compactInset = DSSpacing.sm + DSSpacing.xxs
    private static let partSpacing = DSSpacing.sm + DSSpacing.xxs

    /// The capsule's content: the state word, then the counts while there is room for them.
    @ViewBuilder
    private var summary: some View {
        HStack(spacing: Self.partSpacing) {
            stateLabel
            if !compact, isRunning, !restartRequired {
                separatorDot
                Text(Self.requestCountShort(requestCount))
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                if unmatchedCount > 0 {
                    separatorDot
                    DSStatusLabel("\(unmatchedCount) unmatched", color: DSColors.warning)
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch serverState {
        case .starting, .stopping:
            HStack(spacing: DSSpacing.xs + DSSpacing.xxs) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
                Text(Self.shortState(serverState))
                    .font(DSTypography.calloutMedium)
                    .foregroundStyle(DSColors.labelSecondary)
            }
        case .stopped:
            // A grey dot and a secondary word: stopped is a state, not a warning.
            HStack(spacing: DSSpacing.xs + DSSpacing.xxs) {
                Circle()
                    .fill(DSColors.labelTertiary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(stateTitle)
                    .font(DSTypography.calloutMedium)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
            }
            .fixedSize()
        default:
            DSStatusLabel(stateTitle, color: statusColor)
        }
    }

    private var separatorDot: some View {
        Text(verbatim: "·")
            .font(DSTypography.callout)
            .foregroundStyle(DSColors.labelTertiary)
            .accessibilityHidden(true)
    }

    private var stateTitle: String {
        if restartRequired { return "Restart required" }
        if case .error(let message) = serverState {
            return compact ? "Server error" : "Couldn\u{2019}t start: \(Self.shortError(message))"
        }
        return Self.shortState(serverState)
    }

    private var serverDetails: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack(spacing: DSSpacing.sm) {
                DSStatusLabel(restartRequired ? "Restart required" : Self.shortState(serverState),
                              color: statusColor)
                if isRunning, let runningSince {
                    Text(Self.sinceText(runningSince))
                        .font(DSTypography.callout)
                        .foregroundStyle(DSColors.labelTertiary)
                        .accessibilityIdentifier("serverStatusWell.since")
                }
                Spacer(minLength: DSSpacing.sm)
                if let onToggleServer {
                    DSButton(isRunning ? "Stop" : "Run", variant: .secondary, size: .medium,
                             identifier: "serverStatusWell.toggle") {
                        onToggleServer()
                    }
                }
            }

            if case .error(let message) = serverState {
                Text(verbatim: message)
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.error)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("serverStatusWell.error")
            }

            DSDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.sm) {
                    ForEach(backends) { backend in
                        backendRow(backend)
                    }
                    if restartRequired, let configuration {
                        Text("After a restart")
                            .font(DSTypography.captionSemibold)
                            .foregroundStyle(DSColors.labelTertiary)
                            .padding(.top, DSSpacing.xs)
                        ForEach(configuration.listeners) { backend in
                            HStack {
                                Text(verbatim: backend.name)
                                Spacer(minLength: DSSpacing.sm)
                                Text(verbatim: "localhost:\(backend.port)")
                                    .font(DSTypography.code)
                                    .foregroundStyle(DSColors.warning)
                            }
                            .font(DSTypography.body)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("serverStatusWell.configuredPort.\(backend.port)")
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)

            DSDivider()

            HStack(alignment: .bottom, spacing: 18) {
                figure("\(requestCount)", caption: requestCount == 1 ? "request" : "requests",
                       color: DSColors.labelPrimary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.requestCountLabel(requestCount))
                    .accessibilityIdentifier("serverStatusWell.requestCount")
                figure("\(unmatchedCount)", caption: "unmatched",
                       color: unmatchedCount > 0 ? DSColors.warning : DSColors.labelPrimary)
                Spacer(minLength: DSSpacing.sm)
                // Always offered, as the design has it: with nothing unmatched it opens the log on
                // an Unmatched scope that says so.
                if let onShowUnmatched {
                    DSButton("Show unmatched", variant: .secondary, size: .medium,
                             identifier: "serverStatusWell.unmatchedButton") {
                        showingDetails = false
                        onShowUnmatched()
                    }
                    .accessibilityIdentifier("serverStatusWell.unmatched")
                    .accessibilityLabel(unmatchedCount > 0
                        ? Self.unmatchedLabel(unmatchedCount, actionable: true) : "Show unmatched")
                    .help("Show requests no endpoint or journey answered")
                }
            }

            if let onShowSettings {
                DSDivider()
                Button("Server settings\u{2026}") {
                    showingDetails = false
                    onShowSettings()
                }
                .buttonStyle(.plain)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.accent)
                .accessibilityIdentifier("serverStatusWell.settings")
                .accessibilityLabel("Server settings")
            }
        }
        .padding(DSSpacing.lg)
        .frame(width: DSLayout.popoverWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serverStatusWell.portList")
    }

    private func figure(_ value: String, caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: value)
                .font(DSTypography.Figure.large)
                .foregroundStyle(color)
            Text(caption)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelSecondary)
        }
    }

    private func backendRow(_ backend: BackendConfiguration) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Text(verbatim: backend.name)
                .font(DSTypography.body)
                .lineLimit(1)
            Spacer(minLength: DSSpacing.sm)
            Text(verbatim: "localhost:\(backend.port)")
                .font(DSTypography.code)
                .foregroundStyle(DSColors.labelSecondary)
                .textSelection(.enabled)
                .accessibilityIdentifier(isRunning
                    ? "serverStatusWell.listeningPort.\(backend.port)"
                    : "serverStatusWell.configuredPort.\(backend.port)")
            Button { copyURL(for: backend) } label: {
                Text(copiedPort == backend.port ? "Copied" : "Copy")
                    .frame(minWidth: 40)
            }
            .buttonStyle(.ds(.secondary, size: .small))
            .disabled(!isRunning)
            .accessibilityIdentifier("serverStatusWell.copyPort.\(backend.port)")
            .accessibilityLabel("Copy \(backend.name) URL, port \(String(backend.port))")
            .accessibilityValue(copiedPort == backend.port ? "Copied" : "")
            .help("Copy \(backend.localURL)")
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

    /// "since 21:32": the time of day the server started, in the reader's clock.
    nonisolated static func sinceText(_ date: Date) -> String {
        "since \(date.formatted(date: .omitted, time: .shortened))"
    }

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

    nonisolated static func requestCountShort(_ count: Int) -> String {
        "\(count) \(count == 1 ? "request" : "requests")"
    }

    /// The first clause of a start error, short enough for the toolbar.
    nonisolated static func shortError(_ message: String) -> String {
        let clause = message.split(whereSeparator: { ".\n".contains($0) }).first.map(String.init) ?? message
        return clause.count > 48 ? String(clause.prefix(47)) + "\u{2026}" : clause
    }

    nonisolated static func requestCountLabel(_ count: Int) -> String {
        count == 0 ? "No requests logged" : "\(count) \(count == 1 ? "request" : "requests") logged"
    }

    nonisolated static func unmatchedLabel(_ count: Int, actionable: Bool) -> String {
        let subject = count == 1 ? "1 unmatched request" : "\(count) unmatched requests"
        return actionable ? "\(subject), show \(count == 1 ? "it" : "them")" : subject
    }
}
