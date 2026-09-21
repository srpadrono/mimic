import SwiftUI
import Domain
import DesignSystem

/// Xcode-style Run/Stop control: one target whose symbol changes in place.
struct ServerToggleButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let serverState: ServerState
    let onStart: () -> Void
    let onStop: () -> Void

    static func canStart(in state: ServerState) -> Bool {
        switch state {
        case .stopped, .error: true
        default: false
        }
    }

    static func canStop(in state: ServerState) -> Bool { state.runningPort != nil }

    private var stopIsCurrentAction: Bool {
        switch serverState {
        case .running, .stopping: true
        default: false
        }
    }

    private var isTransitioning: Bool {
        switch serverState {
        case .starting, .stopping: true
        default: false
        }
    }

    private var isRunning: Bool { serverState.runningPort != nil }

    var body: some View {
        Button(action: stopIsCurrentAction ? onStop : onStart) {
            Image(systemName: stopIsCurrentAction ? "stop.fill" : "play.fill")
                .font(.system(size: DSGlyph.toolbar, weight: .semibold))
                .foregroundStyle(DSColors.labelPrimary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp.byLayer))
                .symbolEffect(.pulse, options: .repeating, isActive: isTransitioning && !reduceMotion)
                .frame(width: DSToolbarGeometry.contentHeight, height: DSToolbarGeometry.contentHeight)
                .opacity(isTransitioning ? 0.6 : 1)
                .frame(width: DSToolbarGeometry.height, height: DSToolbarGeometry.height)
                .contentShape(.circle)
        }
        // Keep the label hosted in SwiftUI so the symbol replacement can animate in the toolbar.
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(isRunning ? DSColors.success : .clear).interactive(), in: .circle)
        .disabled(isTransitioning)
        .help(stopIsCurrentAction ? "Stop server" : "Start server")
        .accessibilityLabel(stopIsCurrentAction ? "Stop server" : "Start server")
        .accessibilityIdentifier("serverToggleButton")
        .animation(reduceMotion ? nil : .easeInOut(duration: DSAnimation.normal), value: serverState)
    }
}
