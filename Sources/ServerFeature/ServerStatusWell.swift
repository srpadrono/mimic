import AppKit
import SwiftUI
import Domain
import DesignSystem

/// The toolbar's address and server state as one control: "localhost:18086 +1" over "Running ·
/// 142 requests · 3 unmatched". Clicking it opens the server details, where every address is copied
/// or opened in the browser.
public struct ServerStatusWell: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let serverState: ServerState
    let projectName: String?
    let requestCount: Int
    let unmatchedCount: Int
    /// Narrow toolbars keep the state word and drop the request counts and the restart detail.
    var compact = false
    /// "+1" after the address; compact toolbars leave the count to the details popover.
    var showsListenerCount = true
    var configuration: ServerConfiguration?
    var boundConfiguration: ServerConfiguration?
    /// When the server started serving; the popover says "since 21:32" beside Running.
    var runningSince: Date?
    /// The port a failed start found taken, when that is why it failed.
    var conflictingPort: Int?
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

    public init(
        serverState: ServerState,
        projectName: String? = nil,
        requestCount: Int,
        unmatchedCount: Int,
        compact: Bool = false,
        showsListenerCount: Bool = true,
        configuration: ServerConfiguration? = nil,
        boundConfiguration: ServerConfiguration? = nil,
        runningSince: Date? = nil,
        conflictingPort: Int? = nil,
        onShowUnmatched: (() -> Void)? = nil,
        onShowSettings: (() -> Void)? = nil,
        onToggleServer: (() -> Void)? = nil
    ) {
        self.serverState = serverState
        self.projectName = projectName
        self.requestCount = requestCount
        self.unmatchedCount = unmatchedCount
        self.compact = compact
        self.showsListenerCount = showsListenerCount
        self.configuration = configuration
        self.boundConfiguration = boundConfiguration
        self.runningSince = runningSince
        self.conflictingPort = conflictingPort
        self.onShowUnmatched = onShowUnmatched
        self.onShowSettings = onShowSettings
        self.onToggleServer = onToggleServer
    }

    public var body: some View {
        Button { showingDetails.toggle() } label: {
            summary
                .padding(.horizontal, DSSpacing.sm)
                // One height in every state, so the toolbar never moves while the server does.
                .frame(height: Self.height)
                .background {
                    RoundedRectangle(cornerRadius: DSCornerRadius.segment, style: .continuous)
                        .fill(isHovered || showingDetails ? DSColors.hover : Color.clear)
                }
                .contentShape(.rect(cornerRadius: DSCornerRadius.segment, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canShowDetails)
        .onHover { isHovered = $0 && canShowDetails }
        .onChange(of: canShowDetails) { _, enabled in
            if !enabled { isHovered = false }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: DSAnimation.fast), value: isHovered)
        .help(detailsDescription)
        .accessibilityIdentifier("serverStatusWell.url")
        .accessibilityLabel("Server details, \(Self.stateDescription(serverState))")
        .accessibilityValue(detailsDescription)
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) { serverDetails }
        .onChange(of: serverState) { _, _ in copiedPort = nil }
        .onDisappear { copyResetTask?.cancel() }
    }

    /// Two lines of text and a little air, on the 32pt prominent rung plus one spacing step.
    static let height: CGFloat = DSControlHeight.prominent + DSSpacing.xs

    /// Two lines, as the toolbar design draws them: where the mock serves, with a chevron that says
    /// the address opens something, and under it the state and, while there is room, the counts.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 1) {
            addressLine
            statusLine
        }
        .fixedSize()
    }

    private var addressLine: some View {
        let address = Self.addressTitle(serverState: serverState, configuration: configuration,
                                        boundConfiguration: boundConfiguration)
        return HStack(spacing: DSSpacing.xs) {
            Text(verbatim: address.primary)
                .font(DSTypography.body)
                .foregroundStyle(DSColors.labelPrimary)
            if showsListenerCount, address.others > 0 {
                Text(verbatim: "+\(address.others)")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelTertiary)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: DSGlyph.minimum, weight: .semibold))
                .imageScale(.small)
                .foregroundStyle(DSColors.labelSecondary)
                .accessibilityHidden(true)
        }
        .lineLimit(1)
    }

    private var statusLine: some View {
        HStack(spacing: DSSpacing.xs + DSSpacing.xxs) {
            stateLabel
            if !compact, isRunning, !restartRequired {
                separatorDot
                Text(Self.requestCountShort(requestCount))
                    .foregroundStyle(DSColors.labelSecondary)
                if unmatchedCount > 0 {
                    separatorDot
                    Text("\(unmatchedCount) unmatched")
                        .foregroundStyle(DSColors.warning)
                }
            }
        }
        .font(DSTypography.caption)
        .lineLimit(1)
    }

    @ViewBuilder
    private var stateLabel: some View {
        HStack(spacing: DSSpacing.xs + 1) {
            switch serverState {
            case .starting, .stopping:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
            default:
                DSStatusDot(statusColor)
            }
            Text(stateTitle)
                .foregroundStyle(stateTitleColor)
        }
    }

    /// Running and trouble take their tone; stopped and the transitions are ordinary words.
    private var stateTitleColor: Color {
        if restartRequired { return DSColors.warning }
        switch serverState {
        case .running: return DSColors.success
        case .error: return DSColors.error
        case .stopped, .starting, .stopping: return DSColors.labelSecondary
        }
    }

    private var separatorDot: some View {
        Text(verbatim: "·")
            .foregroundStyle(DSColors.labelTertiary)
            .accessibilityHidden(true)
    }

    private var stateTitle: String {
        if restartRequired, !compact, let configuration, let boundConfiguration {
            return Self.restartTitle(changes: Self.portChangeCount(configuration: configuration,
                                                                   boundConfiguration: boundConfiguration))
        }
        return Self.capsuleStateTitle(serverState: serverState, restartRequired: restartRequired,
                                      conflictingPort: conflictingPort, compact: compact)
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

            // The counts keep their 18pt gap between themselves only; around the spacer the gap is
            // the ordinary one, so "Show unmatched" has room for its whole label.
            HStack(alignment: .bottom, spacing: DSSpacing.sm) {
                HStack(alignment: .bottom, spacing: 18) {
                    figure("\(requestCount)", caption: requestCount == 1 ? "request" : "requests",
                           color: DSColors.labelPrimary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Self.requestCountLabel(requestCount))
                        .accessibilityIdentifier("serverStatusWell.requestCount")
                    figure("\(unmatchedCount)", caption: "unmatched",
                           color: unmatchedCount > 0 ? DSColors.warning : DSColors.labelPrimary)
                }
                Spacer(minLength: 0)
                // Always offered, as the design has it: with nothing unmatched it opens the log on
                // an Unmatched scope that says so.
                if let onShowUnmatched {
                    DSButton("Show unmatched", variant: .secondary, size: .medium,
                             identifier: "serverStatusWell.unmatchedButton") {
                        showingDetails = false
                        onShowUnmatched()
                    }
                    // Its whole label, always; the counts and the spacer give way instead.
                    .fixedSize()
                    .layoutPriority(1)
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
                .frame(minWidth: 88, alignment: .leading)
            Text(verbatim: "localhost:\(backend.port)")
                .font(DSTypography.code)
                .foregroundStyle(DSColors.labelPrimary)
                .textSelection(.enabled)
                .accessibilityIdentifier(isRunning
                    ? "serverStatusWell.listeningPort.\(backend.port)"
                    : "serverStatusWell.configuredPort.\(backend.port)")
            Spacer(minLength: DSSpacing.sm)
            portButton(systemImage: "safari", help: "Open \(backend.localURL) in your browser") {
                openInBrowser(backend)
            }
            .accessibilityIdentifier("serverStatusWell.openPort.\(backend.port)")
            .accessibilityLabel("Open \(backend.name) in browser, port \(String(backend.port))")
            portButton(systemImage: copiedPort == backend.port ? "checkmark" : "doc.on.doc",
                       help: "Copy \(backend.localURL)") {
                copyURL(for: backend)
            }
            .accessibilityIdentifier("serverStatusWell.copyPort.\(backend.port)")
            .accessibilityLabel("Copy \(backend.name) URL, port \(String(backend.port))")
            .accessibilityValue(copiedPort == backend.port ? "Copied" : "")
        }
    }

    /// A port's quiet icon action. Both need a listener, so both wait for the server.
    private func portButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: DSGlyph.field, weight: .regular))
                .foregroundStyle(DSColors.labelSecondary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dsHoverHighlight()
        .disabled(!isRunning)
        .help(help)
    }

    private func openInBrowser(_ backend: BackendConfiguration) {
        guard isRunning, let url = URL(string: backend.localURL) else { return }
        NSWorkspace.shared.open(url)
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

    /// The toolbar's address: the first listener, and how many others the project serves on.
    nonisolated static func addressTitle(
        serverState: ServerState, configuration: ServerConfiguration?, boundConfiguration: ServerConfiguration?
    ) -> (primary: String, others: Int) {
        let listeners = displayedBackends(serverState: serverState, configuration: configuration,
                                          boundConfiguration: boundConfiguration)
        guard let first = listeners.first else { return ("No project", 0) }
        return ("localhost:\(first.port)", listeners.count - 1)
    }

    /// How many listeners a restart would add, remove or move to another port.
    nonisolated static func portChangeCount(
        configuration: ServerConfiguration, boundConfiguration: ServerConfiguration
    ) -> Int {
        let configured = Dictionary(configuration.listeners.map { ($0.id, $0.port) }, uniquingKeysWith: { a, _ in a })
        let bound = Dictionary(boundConfiguration.listeners.map { ($0.id, $0.port) }, uniquingKeysWith: { a, _ in a })
        return Set(configured.keys).union(bound.keys).filter { configured[$0] != bound[$0] }.count
    }

    /// "Restart to apply 2 port changes", the running server's warning line.
    nonisolated static func restartTitle(changes: Int) -> String {
        changes == 1 ? "Restart to apply 1 port change" : "Restart to apply \(changes) port changes"
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

    /// The capsule's state word. It stays about as wide as "Running" or "Stopped" where the toolbar
    /// is narrow: a longer word pushes Run and "More actions" behind AppKit's own overflow chevron,
    /// since `WorkspaceView.toolbarLayout` budgets the capsule at under 100pt from the narrow tier
    /// down. A port conflict reads as the design words it, "Couldn't start: port 8080 in use"; the
    /// popover and the capsule's help carry the whole sentence either way.
    nonisolated static func capsuleStateTitle(
        serverState: ServerState, restartRequired: Bool, conflictingPort: Int?, compact: Bool
    ) -> String {
        if restartRequired { return compact ? "Restart" : "Restart required" }
        if case .error(let message) = serverState {
            if compact { return "Server error" }
            if let conflictingPort { return "Couldn\u{2019}t start: port \(conflictingPort) in use" }
            return "Couldn\u{2019}t start: \(shortError(message))"
        }
        return shortState(serverState)
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
