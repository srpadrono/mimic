import SwiftUI

/// A labeled loading skeleton. Pulsing stops when hidden or Reduce Motion is enabled.
public struct DSLoadingPlaceholder: View {
    // A repeating pulse has its own duration, separate from transition timing tokens.
    private static let pulseDuration: Double = 1.1

    // Keep the skeleton visible at both ends of the pulse.
    private static let restOpacity: Double = 0.9
    private static let troughOpacity: Double = 0.55

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOnScreen = false
    private let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            placeholderBar(width: 200, height: 18)
            placeholderBar(width: 300, height: 12)
            placeholderBar(width: nil, height: 80)
        }
        .opacity(shouldPulse ? Self.troughOpacity : Self.restOpacity)
        .animation(pulseAnimation, value: shouldPulse)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement()
        .accessibilityIdentifier("ds.loading.\(identifier)")
        .accessibilityLabel("Loading")
    }

    /// Both visibility and the live accessibility setting determine whether to animate.
    private var shouldPulse: Bool {
        isOnScreen && !reduceMotion
    }

    /// A non-repeating animation settles the bars when pulsing is disabled.
    private var pulseAnimation: Animation {
        shouldPulse
            ? .easeInOut(duration: Self.pulseDuration).repeatForever(autoreverses: true)
            : .default
    }

    private func placeholderBar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: DSCornerRadius.xs)
            .fill(DSColors.tertiary)
            .frame(maxWidth: width ?? .infinity, minHeight: height, maxHeight: height)
    }
}
