import AppKit
import SwiftUI
import Domain
import DesignSystem

/// What the server status well opens: the state and when it started, every address with its Copy
/// and Open in browser actions, the request counts, and the way to the server settings.
///
/// Public so the gallery can draw it on its own; a popover never draws offscreen.
public struct ServerStatusDetails: View {
    /// "since 21:32" follows the reader's clock; the gallery pins it.
    @Environment(\.locale) private var locale

    let serverState: ServerState
    let requestCount: Int
    let unmatchedCount: Int
    let configuration: ServerConfiguration?
    let boundConfiguration: ServerConfiguration?
    let runningSince: Date?
    let onShowUnmatched: (() -> Void)?
    let onShowSettings: (() -> Void)?
    let onToggleServer: (() -> Void)?
    /// Closes the popover before an action that takes the reader elsewhere.
    let onDismiss: () -> Void

    @State private var copiedPort: Int?
    @State private var copyResetTask: Task<Void, Never>?

    public init(
        serverState: ServerState,
        requestCount: Int,
        unmatchedCount: Int,
        configuration: ServerConfiguration?,
        boundConfiguration: ServerConfiguration?,
        runningSince: Date?,
        onShowUnmatched: (() -> Void)?,
        onShowSettings: (() -> Void)?,
        onToggleServer: (() -> Void)?,
        onDismiss: @escaping () -> Void
    ) {
        self.serverState = serverState
        self.requestCount = requestCount
        self.unmatchedCount = unmatchedCount
        self.configuration = configuration
        self.boundConfiguration = boundConfiguration
        self.runningSince = runningSince
        self.onShowUnmatched = onShowUnmatched
        self.onShowSettings = onShowSettings
        self.onToggleServer = onToggleServer
        self.onDismiss = onDismiss
    }

    private var isRunning: Bool { serverState.runningPort != nil }
    private var restartRequired: Bool {
        ServerStatusWell.requiresRestart(serverState: serverState, configuration: configuration,
                                         boundConfiguration: boundConfiguration)
    }
    private var backends: [BackendConfiguration] {
        ServerStatusWell.displayedBackends(serverState: serverState, configuration: configuration,
                                           boundConfiguration: boundConfiguration)
    }
    private var statusColor: Color {
        ServerStatusWell.statusColor(serverState: serverState, restartRequired: restartRequired)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack(spacing: DSSpacing.sm) {
                // 13pt, as the popover design sets its state; the toolbar's labels are 12.
                HStack(spacing: 6) {
                    DSStatusDot(statusColor)
                    Text(restartRequired ? "Restart required" : ServerStatusWell.shortState(serverState))
                        .font(DSTypography.bodyMedium)
                        .lineLimit(1)
                }
                .foregroundStyle(statusColor)
                .fixedSize()
                .accessibilityElement(children: .combine)
                if isRunning, let runningSince {
                    Text(ServerStatusWell.sinceText(runningSince, locale: locale))
                        .font(DSTypography.callout)
                        .foregroundStyle(DSColors.labelTertiary)
                        .accessibilityIdentifier("serverStatusWell.since")
                }
                Spacer(minLength: DSSpacing.sm)
                if let onToggleServer {
                    DSButton(isRunning ? "Stop" : "Run", variant: .secondary, size: .inline,
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
            HStack(alignment: .center, spacing: DSSpacing.sm) {
                HStack(alignment: .center, spacing: 18) {
                    figure("\(requestCount)", caption: requestCount == 1 ? "request" : "requests",
                           color: DSColors.labelPrimary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(ServerStatusWell.requestCountLabel(requestCount))
                        .accessibilityIdentifier("serverStatusWell.requestCount")
                    figure("\(unmatchedCount)", caption: "unmatched",
                           color: unmatchedCount > 0 ? DSColors.warning : DSColors.labelPrimary)
                }
                Spacer(minLength: 0)
                // Always offered, as the design has it: with nothing unmatched it opens the log on
                // an Unmatched scope that says so.
                if let onShowUnmatched {
                    DSButton("Show unmatched", variant: .secondary, size: .inline,
                             identifier: "serverStatusWell.unmatchedButton") {
                        onDismiss()
                        onShowUnmatched()
                    }
                    // Its whole label, always; the counts and the spacer give way instead.
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityIdentifier("serverStatusWell.unmatched")
                    .accessibilityLabel(unmatchedCount > 0
                        ? ServerStatusWell.unmatchedLabel(unmatchedCount, actionable: true) : "Show unmatched")
                    .help("Show requests no endpoint or journey answered")
                }
            }

            if let onShowSettings {
                DSDivider()
                Button("Server settings\u{2026}") {
                    onDismiss()
                    onShowSettings()
                }
                .buttonStyle(.plain)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.accent)
                .accessibilityIdentifier("serverStatusWell.settings")
                .accessibilityLabel("Server settings")
            }
        }
        .padding(DSLayout.popoverPadding)
        .frame(width: DSLayout.popoverWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serverStatusWell.portList")
        .onChange(of: serverState) { _, _ in copiedPort = nil }
        .onDisappear { copyResetTask?.cancel() }
    }

    /// A count over its word, on the design's 20pt and 16pt lines.
    private func figure(_ value: String, caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: value)
                .font(DSTypography.Figure.largeText)
                .foregroundStyle(color)
                .frame(height: 20, alignment: .leading)
            Text(caption)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelSecondary)
                .frame(height: 16, alignment: .leading)
        }
    }

    /// Name, address, then the address's two actions: open it in the browser, and copy it.
    private func backendRow(_ backend: BackendConfiguration) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Text(verbatim: backend.name)
                .font(DSTypography.body)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "localhost:\(backend.port)")
                .font(DSTypography.code)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .fixedSize()
                .textSelection(.enabled)
                .accessibilityIdentifier(isRunning
                    ? "serverStatusWell.listeningPort.\(backend.port)"
                    : "serverStatusWell.configuredPort.\(backend.port)")
            openButton(for: backend)
            DSButton(copiedPort == backend.port ? "Copied" : "Copy", variant: .secondary, size: .inline,
                     identifier: "serverStatusWell.copy.\(backend.port)") {
                copyURL(for: backend)
            }
            .fixedSize()
            .disabled(!isRunning)
            .help("Copy \(backend.localURL)")
            // Outside DSButton's own identifier, so the name the UI tests hold wins.
            .accessibilityIdentifier("serverStatusWell.copyPort.\(backend.port)")
            .accessibilityLabel("Copy \(backend.name) URL, port \(String(backend.port))")
            .accessibilityValue(copiedPort == backend.port ? "Copied" : "")
        }
    }

    /// The quiet 22pt icon button before Copy. It needs a listener, so it waits for the server.
    private func openButton(for backend: BackendConfiguration) -> some View {
        Button {
            openInBrowser(backend)
        } label: {
            Image(systemName: "safari")
                .font(.system(size: DSGlyph.field, weight: .regular))
                .foregroundStyle(DSColors.labelSecondary)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dsHoverHighlight()
        .disabled(!isRunning)
        .help("Open \(backend.localURL) in your browser")
        .accessibilityIdentifier("serverStatusWell.openPort.\(backend.port)")
        .accessibilityLabel("Open \(backend.name) in browser, port \(String(backend.port))")
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
}
