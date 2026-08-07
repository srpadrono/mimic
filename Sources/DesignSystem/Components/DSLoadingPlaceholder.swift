import SwiftUI

/// The skeleton a panel shows while its content is still being prepared.
///
/// It pulses, and a pulse is a perpetual animation, which makes three things mandatory — the same
/// three `DSStatusBadge` had to learn for its running-server halo.
///
/// **Reduce Motion is re-read, not read once.** The old version consulted it in `onAppear` and never
/// again, so turning Reduce Motion on while a 64 KB body was formatting left the loop running for as
/// long as the placeholder was on screen. `shouldPulse` is derived from the environment, so the
/// animation settles on the frame the setting changes.
///
/// **It stops when it leaves the screen.** `repeatForever` outlives its view's *visibility*, not its
/// lifetime: a placeholder inside a closed inspector or a collapsed drawer went on driving a
/// render loop against something nobody was looking at. `onDisappear` ends it — and ends it by
/// flipping the same derived flag, so the animation in force at that moment is the non-repeating one
/// and the opacity settles instead of starting a fresh infinite cycle.
///
/// **The trough stays legible.** The bars used to fade to 30% of `DSColors.surfaceWell`, which on the
/// canvas is very nearly the canvas: half of every cycle showed an empty panel, which reads as
/// "nothing is happening" rather than "something is on its way".
public struct DSLoadingPlaceholder: View {
    /// Slow enough to read as breathing rather than blinking. Deliberately not a `DSAnimation` token:
    /// those are transition durations, and a skeleton is neither a transition nor a progress bar —
    /// it must not imply a rate.
    private static let pulseDuration: Double = 1.1

    /// Both ends of the pulse show the skeleton. The distance between them is the animation; the
    /// floor is what keeps the panel from looking blank at the bottom of each cycle.
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
        // One reading, not three anonymous rectangles. The bars are decoration; the single fact a
        // screen reader needs from this view is that content is on its way, and without a label the
        // identifier named an element with nothing to say.
        .accessibilityElement()
        .accessibilityIdentifier("ds.loading.\(identifier)")
        .accessibilityLabel("Loading")
    }

    /// Visible *and* allowed to move. Both inputs feed the opacity and the animation, so the two can
    /// never disagree about whether a cycle is running.
    private var shouldPulse: Bool {
        isOnScreen && !reduceMotion
    }

    /// Repeats only while it should be pulsing; otherwise a plain non-repeating animation, so the
    /// bars settle at rest instead of freezing mid-fade.
    private var pulseAnimation: Animation {
        shouldPulse
            ? .easeInOut(duration: Self.pulseDuration).repeatForever(autoreverses: true)
            : .default
    }

    /// `nil` width means "take the room available". It used to be `.infinity` passed as a `CGFloat`
    /// and compared back against `.infinity`, which is a sentinel doing an optional's job.
    private func placeholderBar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: DSCornerRadius.xs)
            .fill(DSColors.surfaceWell)
            .frame(maxWidth: width ?? .infinity, minHeight: height, maxHeight: height)
    }
}
