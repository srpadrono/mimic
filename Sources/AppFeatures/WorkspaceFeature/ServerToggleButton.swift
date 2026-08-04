import SwiftUI
import Domain
import DesignSystem

/// Icon-only server power button — color and shape communicate state.
///
/// - **Stopped/Error:** muted play icon
/// - **Running:** green power icon with pulse glow
/// - **Starting/Stopping:** spinning progress indicator
struct ServerToggleButton: View {
    let serverState: ServerState
    let onStart: () -> Void
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    public init(serverState: ServerState, onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.serverState = serverState
        self.onStart = onStart
        self.onStop = onStop
    }

    public var body: some View {
        Button(action: handleTap) {
            ZStack {
                // One shape doing two jobs: the running glow and the hover well. Drawn always rather
                // than only while running, because it was the second job this control did not do at
                // all — the app's primary action was the one icon in the window that never
                // acknowledged the pointer, which in a toolbar of AppKit items that all do reads as a
                // picture of a button rather than a button.
                Circle()
                    .fill(wellFill)
                    .frame(width: 26, height: 26)

                Image(systemName: iconName)
                    .font(.system(size: isTransitioning ? 10 : 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    // Gated on Reduce Motion. `ServerStatusWell` in the same toolbar already does
                    // this; a perpetual rotation is exactly what the setting exists to stop.
                    .symbolEffect(.rotate, isActive: isTransitioning && !reduceMotion)
            }
            // 34pt, and deliberately larger than the 18–22pt every other icon control in the window
            // takes. Those live in panel chrome; this is a toolbar item, where AppKit's own targets
            // run about this size — and it is the one action the whole app exists to perform. Xcode
            // sizes its Run button above its neighbours for the same reason. Not a stray number.
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isTransitioning)
        // Nothing to light up while the server is mid-transition: the button is disabled, and a well
        // that answers a pointer that cannot click is the same lie as a live-looking dead control.
        .onHover { isHovered = $0 && !isTransitioning }
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("serverToggleButton")
    }

    /// The circle behind the glyph.
    ///
    /// Running, it is the state glow and hover deepens it — the well keeps saying "running" while it
    /// answers the pointer, rather than being overpainted by a blue that means nothing here. Every
    /// other state gets the `accentSubtle` fill `DSTabStrip`'s tabs and the journey navigator's
    /// activation ring use for exactly this shape.
    private var wellFill: Color {
        if isRunning {
            return DSColors.serverRunning.opacity(isHovered ? 0.28 : 0.15)
        }
        return isHovered ? DSColors.accentSubtle : .clear
    }

    // MARK: - State-derived properties

    private var isRunning: Bool {
        if case .running = serverState { return true }
        return false
    }

    private var isTransitioning: Bool {
        if case .starting = serverState { return true }
        if case .stopping = serverState { return true }
        return false
    }

    private var iconName: String {
        switch serverState {
        case .stopped, .error:       "play.fill"
        case .starting, .stopping:   "arrow.triangle.2.circlepath"
        case .running:               "stop.fill"
        }
    }

    private var iconColor: Color {
        switch serverState {
        // Not `labelTertiary`: at 36% alpha the app's primary action was faintest in precisely the
        // state where you need to find and press it. `DSPanelHeaderButton` recorded this same fix for
        // the panel buttons.
        case .stopped:               DSColors.labelSecondary
        case .starting, .stopping:   DSColors.labelSecondary
        case .running:               DSColors.serverRunning
        case .error:                 DSColors.serverError
        }
    }

    private var helpText: String {
        switch serverState {
        case .stopped, .error: "Start server"
        case .running:         "Stop server"
        case .starting:        "Starting\u{2026}"
        case .stopping:        "Stopping\u{2026}"
        }
    }

    private var accessibilityLabel: String {
        switch serverState {
        case .stopped:        "Start server"
        case .starting:       "Starting, please wait"
        case .running:        "Stop server, running"
        case .stopping:       "Stopping, please wait"
        case .error(let msg): "Start server, error: \(msg)"
        }
    }

    private func handleTap() {
        Self.performAction(serverState: serverState, onStart: onStart, onStop: onStop)
    }

    static func performAction(serverState: ServerState, onStart: () -> Void, onStop: () -> Void) {
        switch serverState {
        case .stopped, .error: onStart()
        case .running:         onStop()
        default:               break
        }
    }
}
