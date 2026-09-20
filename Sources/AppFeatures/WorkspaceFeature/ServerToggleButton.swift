import SwiftUI
import Domain
import DesignSystem

/// Stable native Run and Stop controls. State changes availability, never their placement.
struct ServerToggleButton: View {
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

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Button(action: onStart) {
                Label("Start server", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: DSControlHeight.prominent, height: DSControlHeight.prominent)
            }
            .disabled(!Self.canStart(in: serverState))
            .help("Start server")
            .accessibilityLabel("Start server")
            .accessibilityIdentifier(stopIsCurrentAction ? "serverStartButton" : "serverToggleButton")

            Button(action: onStop) {
                Label("Stop server", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: DSControlHeight.prominent, height: DSControlHeight.prominent)
            }
            .disabled(!Self.canStop(in: serverState))
            .help("Stop server")
            .accessibilityLabel("Stop server")
            .accessibilityIdentifier(stopIsCurrentAction ? "serverToggleButton" : "serverStopButton")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbar.serverControls")
    }

}
