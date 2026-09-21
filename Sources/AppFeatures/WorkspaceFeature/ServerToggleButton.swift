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

    var body: some View {
        Button(action: stopIsCurrentAction ? onStop : onStart) {
            Image(systemName: stopIsCurrentAction ? "stop.fill" : "play.fill")
                .font(.system(size: DSGlyph.controlProminent, weight: .semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp.byLayer))
                .frame(width: DSToolbarGeometry.contentHeight, height: DSToolbarGeometry.contentHeight)
                .contentShape(.rect)
                .opacity(isTransitioning ? 0 : 1)
                .overlay {
                    if isTransitioning {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(DSToolbarButtonStyle())
        .disabled(isTransitioning)
        .help(stopIsCurrentAction ? "Stop server" : "Start server")
        .accessibilityLabel(stopIsCurrentAction ? "Stop server" : "Start server")
        .accessibilityIdentifier("serverToggleButton")
        .animation(reduceMotion ? nil : .easeInOut(duration: DSAnimation.micro), value: stopIsCurrentAction)
    }
}
