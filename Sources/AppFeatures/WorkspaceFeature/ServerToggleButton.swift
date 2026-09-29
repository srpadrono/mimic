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

    /// Whether the button reads Stop: while the server runs, and while it is on its way down.
    static func stopIsCurrentAction(in state: ServerState) -> Bool {
        switch state {
        case .running, .stopping: true
        default: false
        }
    }

    static func isTransitioning(in state: ServerState) -> Bool {
        switch state {
        case .starting, .stopping: true
        default: false
        }
    }

    private var stopIsCurrentAction: Bool { Self.stopIsCurrentAction(in: serverState) }

    private var isTransitioning: Bool { Self.isTransitioning(in: serverState) }

    var body: some View {
        Button(action: stopIsCurrentAction ? onStop : onStart) {
            Label {
                // Both words laid out, one shown, so the capsule keeps one width when the server starts.
                ZStack(alignment: .leading) {
                    Text("Stop").hidden()
                    Text("Run").hidden()
                    Text(stopIsCurrentAction ? "Stop" : "Run")
                }
            } icon: {
                Image(systemName: stopIsCurrentAction ? "stop.fill" : "play.fill")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: isTransitioning && !reduceMotion)
                    // play.fill and stop.fill differ in width; a fixed slot keeps the capsule still.
                    .frame(width: DSGlyph.control)
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

/// Run and Stop as the first item of the toolbar's "More actions" menu, where the narrowest centre
/// column folds them. Same identifier and spoken name as the toolbar button, so it is the same
/// action wherever it sits.
struct ServerToggleMenuItem: View {
    let serverState: ServerState
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        let stops = ServerToggleButton.stopIsCurrentAction(in: serverState)
        Button(action: stops ? onStop : onStart) {
            Label(stops ? "Stop server" : "Run server", systemImage: stops ? "stop.fill" : "play.fill")
        }
        .disabled(ServerToggleButton.isTransitioning(in: serverState))
        .help(stops ? "Stop server (⇧⌘R)" : "Start server (⇧⌘R)")
        .accessibilityLabel(stops ? "Stop server" : "Start server")
        .accessibilityIdentifier("serverToggleButton")
    }
}
