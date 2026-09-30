import SwiftUI
import Domain
import DesignSystem

/// Run and Stop lead the toolbar as one round glass button. Native toolbar glass draws the circle.
public struct ServerToggleButton: View {
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

    public init(
        serverState: ServerState,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.serverState = serverState
        self.onStart = onStart
        self.onStop = onStop
    }

    public var body: some View {
        Button(action: stopIsCurrentAction ? onStop : onStart) {
            // The title stays in the label: the toolbar publishes it, "Run" or "Stop", as the item's
            // name, while the round glass button shows only the glyph, as Xcode's does.
            Label {
                Text(stopIsCurrentAction ? "Stop" : "Run")
            } icon: {
                Image(systemName: stopIsCurrentAction ? "stop.fill" : "play.fill")
                    .font(.system(size: DSGlyph.field, weight: .semibold))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: isTransitioning && !reduceMotion)
                    // play.fill and stop.fill differ in width; a fixed slot keeps the circle still.
                    .frame(width: DSGlyph.toolbar, height: DSGlyph.toolbar)
            }
            .labelStyle(.iconOnly)
            .opacity(isTransitioning ? 0.6 : 1)
        }
        .buttonBorderShape(.circle)
        .disabled(isTransitioning)
        .help(stopIsCurrentAction ? "Stop server (⇧⌘R)" : "Start server (⇧⌘R)")
        .accessibilityLabel(stopIsCurrentAction ? "Stop server" : "Start server")
        .accessibilityIdentifier("serverToggleButton")
    }
}

/// Run and Stop as the first item of the toolbar's "More actions" menu, where the narrowest centre
/// column folds them. Same identifier and spoken name as the toolbar button, so it is the same
/// action wherever it sits.
public struct ServerToggleMenuItem: View {
    let serverState: ServerState
    let onStart: () -> Void
    let onStop: () -> Void

    public init(
        serverState: ServerState,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.serverState = serverState
        self.onStart = onStart
        self.onStop = onStop
    }

    public var body: some View {
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
