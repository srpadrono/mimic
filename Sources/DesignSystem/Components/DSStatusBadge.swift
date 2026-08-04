import SwiftUI

/// Server state indicator: a coloured dot, a word, and — only when something is wrong — a pill.
///
/// It used to fill for every state, which spent the design system's loudest device on the two
/// pieces of news nobody needs shouted: that the server is idle, and that the server is running
/// normally. A filled coloured capsule is an alarm; four of them in a row and none of them means
/// anything. So the quiet states are a dot and a label on the panel's own surface, and `.error`
/// keeps the tinted capsule and its hairline. Geometry does not change between states — only the
/// fill — so the row around the badge does not shift on the frame the server fails.
public struct DSStatusBadge: View {
    /// Same 20pt as the workspace's other row controls, so a badge dropped into a header lines up.
    private static let height: CGFloat = 20
    /// The dot. Small, but the smallest thing here is still 8pt.
    private static let dotSize: CGFloat = 8

    private let state: DSServerState
    private let identifier: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    public init(state: DSServerState, identifier: String = "server") {
        self.state = state
        self.identifier = identifier
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xs) {
            indicator

            Text(state.label)
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelPrimary)
                // A state word that wraps turns the pill into a two-line block. Truncation is the
                // better failure here, and in practice the longest label is "Stopped".
                .lineLimit(1)
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, 3)
        .frame(height: Self.height)
        .background {
            Capsule().fill(fill)
        }
        .overlay {
            Capsule().stroke(stroke, lineWidth: 0.5)
        }
        .onAppear { isPulsing = shouldPulse }
        .onChange(of: state) { isPulsing = shouldPulse }
        // Reduce Motion was only consulted when the badge appeared and when the state changed, so
        // turning it on mid-run left a perpetual animation running for as long as the server did.
        .onChange(of: reduceMotion) { isPulsing = shouldPulse }
        // A single reading, not a container: there is nothing addressable inside it, and `.contain`
        // would leave the bare word "Running" in the tree next to a badge that already says
        // "Server Running".
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("ds.status.\(identifier)")
        .accessibilityLabel("Server \(state.label)")
    }

    /// A solid dot with a halo expanding out from behind it.
    ///
    /// The pulse used to be applied to the dot and then covered by an identical, unanimated dot
    /// drawn on top of it as an overlay — so the scale and the fade happened underneath something
    /// opaque and nothing ever moved on screen. The halo now sits in the background, where scaling
    /// it takes no part in layout, so the badge is the same width whether it is pulsing or not.
    private var indicator: some View {
        Circle()
            .fill(state.color)
            .frame(width: Self.dotSize, height: Self.dotSize)
            .background {
                Circle()
                    .fill(state.color)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .scaleEffect(isPulsing ? 2.1 : 1.0)
                    .opacity(isPulsing ? 0.0 : 0.45)
            }
            .animation(pulseAnimation, value: isPulsing)
            .accessibilityHidden(true)
    }

    /// Whether the badge is reporting something the user has to do something about. Only that earns
    /// the filled capsule.
    private var needsAttention: Bool {
        state == .error
    }

    private var fill: Color {
        needsAttention ? state.color.opacity(0.16) : .clear
    }

    private var stroke: Color {
        needsAttention ? state.color.opacity(0.30) : .clear
    }

    private var shouldPulse: Bool {
        !reduceMotion && state == .running
    }

    /// Repeats only while running and when Reduce Motion is off; otherwise a non-repeating default,
    /// so the halo settles instead of being frozen mid-expansion.
    private var pulseAnimation: Animation {
        shouldPulse
            ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
            : .default
    }
}
