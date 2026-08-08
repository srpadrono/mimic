import SwiftUI
import Domain
import DesignSystem

/// The server, as one object: run control, address, and what it has served.
///
/// It replaces two controls that sat at opposite ends of the toolbar and described the same thing —
/// `ServerToggleButton` at the leading edge and `ServerStatusWell` in the principal slot. Splitting
/// them meant the app's primary action and the state it produces were never in the same glance, and
/// the redesign's brief names "server state is quiet" as one of the six problems it set out to fix.
///
/// **Every state pairs a glyph with words**, so none of them depends on hue: a stopped server says
/// "Not serving", a conflict says which port is taken. That is what makes this readable in greyscale
/// and under Differentiate Without Color.
///
/// Three things are kept from the controls it replaces, each of which was a fix for a real defect:
///
/// - **`.stopping` disables the run slot.** Without it a second click during teardown reaches the
///   engine, because `MockServerRuntime.stopServer()` sets the state before an async `engine.stop()`.
///   The redesign's own `serverState` enum drops this case; it must not.
/// - **The address copies, and says so.** The copy affordance flashes to a checkmark rather than
///   relying on a toast the toolbar has nowhere to put.
/// - **The unmatched count is a button.** It sets the log's filter. The design demotes it to a
///   static figure, which would remove the one-click path from "something is unmocked" to "here is
///   what".
///
/// The run slot is deliberately narrow and separated by a rule: it is the only *destructive-ish*
/// part of an object that is otherwise a passive readout, and Xcode keeps its Run and Stop discrete
/// for the same reason. Clicking the address copies; clicking the slot toggles; the two do not
/// overlap.
struct DSServerSegment: View {
    let serverState: ServerState
    let requestCount: Int
    let unmatchedCount: Int
    let onStart: () -> Void
    let onStop: () -> Void
    let onShowUnmatched: () -> Void

    @State private var isRunHovered = false
    @State private var isAddressHovered = false
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isTransitioning: Bool {
        serverState == .starting || serverState == .stopping
    }

    private var tint: Color {
        switch serverState {
        case .running: DSColors.success
        case .starting, .stopping: DSColors.accent
        case .error: DSColors.destructive
        case .stopped: DSColors.labelSecondary
        }
    }

    /// Text on the segment's own tinted fill, which is why these are the *deep* variants — the plain
    /// hues measure under 4.5:1 on a 10-13% wash of themselves in light mode.
    private var inkColor: Color {
        switch serverState {
        case .running: DSColors.successDeep
        case .starting, .stopping: DSColors.accentText
        case .error: DSColors.destructiveDeep
        case .stopped: DSColors.labelSecondary
        }
    }

    private var fillOpacity: Double {
        switch serverState {
        case .stopped: 0
        case .error: 0.09
        default: 0.10
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            runSlot

            Rectangle()
                .fill(tint.opacity(0.25))
                .frame(width: 0.5)

            addressSlot

            if serverState.runningPort != nil {
                Rectangle()
                    .fill(tint.opacity(0.25))
                    .frame(width: 0.5)

                trafficSlot
            }
        }
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.lg)
                .fill(tint.opacity(fillOpacity))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DSCornerRadius.lg)
                .stroke(serverState == .stopped ? DSColors.border : tint.opacity(0.28), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serverSegment")
    }

    // MARK: - Run

    private var runSlot: some View {
        Button(action: handleRunTap) {
            Group {
                if isTransitioning {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 10, weight: .semibold))
                        // Reduce Motion gets a static glyph, not a frozen spinner: a stalled
                        // indicator reads as a hang.
                        .symbolEffect(.rotate, isActive: !reduceMotion)
                } else {
                    Image(systemName: serverState.runningPort == nil ? "play.fill" : "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(isTransitioning ? DSColors.labelSecondary : tint)
            .frame(width: 34, height: 30)
            .background(tint.opacity(isRunHovered && !isTransitioning ? 0.16 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.stopping` is why this exists. Without it a second click mid-teardown reaches the engine.
        .disabled(isTransitioning)
        .onHover { isRunHovered = $0 && !isTransitioning }
        .animation(.easeOut(duration: DSAnimation.micro), value: isRunHovered)
        .help(runHelp)
        .accessibilityIdentifier("serverToggleButton")
        .accessibilityLabel(runHelp)
    }

    private var runHelp: String {
        switch serverState {
        case .running: "Stop the mock server"
        case .starting: "Starting the mock server"
        case .stopping: "Stopping the mock server"
        case .stopped: "Start the mock server"
        case .error: "Retry starting the mock server"
        }
    }

    // MARK: - Address

    private var addressSlot: some View {
        HStack(spacing: DSSpacing.xs) {
            if case let .error(message) = serverState {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(message)
                    .font(DSTypography.meta)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let url = ServerStatusWell.copyableURL(serverState: serverState) {
                Text(url.replacingOccurrences(of: "http://", with: ""))
                    .font(DSTypography.codePath)
                    .lineLimit(1)

                // The copy affordance is the click target, not the whole 200pt address region —
                // which sits next to a control that stops the server.
                Button {
                    copyAddress(url)
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 16)
                        .background {
                            RoundedRectangle(cornerRadius: DSCornerRadius.xs)
                                .fill(tint.opacity(isAddressHovered ? 0.18 : 0.10))
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isAddressHovered = $0 }
                .help(didCopy ? "Copied" : "Copy the base URL")
                .accessibilityIdentifier("serverStatusWell.copyButton")
                .accessibilityLabel(didCopy ? "Base URL copied" : "Copy the base URL")
            } else {
                Text(ServerStatusWell.stateDescription(serverState))
                    .font(DSTypography.meta)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(inkColor)
        .padding(.horizontal, DSSpacing.sm)
        .accessibilityIdentifier("serverStatusWell.url")
    }

    private func copyAddress(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }

    // MARK: - Traffic

    private var trafficSlot: some View {
        HStack(spacing: DSSpacing.xs) {
            Text("\(requestCount)")
                .font(DSTypography.Figure.small)
                .foregroundStyle(inkColor)
                .accessibilityLabel(ServerStatusWell.requestCountLabel(requestCount))

            if unmatchedCount > 0 {
                // A button, not a figure. This is the one-click path from "something is unmocked" to
                // the rows that prove it, and the design demotes it to static text.
                Button(action: onShowUnmatched) {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("\(unmatchedCount)")
                            .font(DSTypography.Figure.small)
                    }
                    .foregroundStyle(DSColors.warningDeep)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show only the requests nothing answered")
                .accessibilityIdentifier("serverStatusWell.unmatchedButton")
                .accessibilityLabel(ServerStatusWell.unmatchedLabel(unmatchedCount, actionable: true))
            }
        }
        .padding(.horizontal, DSSpacing.sm)
    }

    /// The tested rule, not a second copy of it.
    ///
    /// `ServerToggleButton.performAction` already encodes "start from stopped or error, stop from
    /// running, do nothing while in transition" and has its own tests. The obvious inline version
    /// here — `runningPort == nil ? onStart() : onStop()` — is subtly different: it would start the
    /// server from `.stopping`, which is exactly the double-click race the disabled state exists to
    /// prevent. Sharing it is cheaper than rediscovering that.
    private func handleRunTap() {
        ServerToggleButton.performAction(serverState: serverState, onStart: onStart, onStop: onStop)
    }
}
