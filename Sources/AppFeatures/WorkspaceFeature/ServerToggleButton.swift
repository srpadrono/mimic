import SwiftUI
import Domain
import DesignSystem

/// Run and Stop carry a word, not just a glyph. Native toolbar glass draws the capsule.
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

    var body: some View {
        Button(action: stopIsCurrentAction ? onStop : onStart) {
            Label {
                Text(stopIsCurrentAction ? "Stop" : "Run")
            } icon: {
                Image(systemName: stopIsCurrentAction ? "stop.fill" : "play.fill")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: isTransitioning && !reduceMotion)
            }
            .labelStyle(.titleAndIcon)
            .font(DSTypography.bodyMedium)
            .opacity(isTransitioning ? 0.6 : 1)
            .padding(.horizontal, DSSpacing.xs)
        }
        .disabled(isTransitioning)
        .help(stopIsCurrentAction ? "Stop server (⇧⌘R)" : "Start server (⇧⌘R)")
        .accessibilityLabel(stopIsCurrentAction ? "Stop server" : "Start server")
        .accessibilityIdentifier("serverToggleButton")
    }
}
