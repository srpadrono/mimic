import SwiftUI

// MARK: - Reduce Motion

/// Runs `animation` only when Reduce Motion is off, and re-reads the setting when it changes.
///
/// There are seven independent `@Environment(\.accessibilityReduceMotion)` reads in this codebase and
/// no shared helper, which is how four separate issues in the redesign plan each came to be told
/// "copy the pattern from `DSStatusBadge`" — a file another issue deletes.
///
/// The part that is easy to get wrong, and the reason this is a modifier rather than a convention:
/// **the setting has to be re-read when it changes, not only when the view appears.** Turning Reduce
/// Motion on mid-run used to leave a perpetual animation running for as long as the server did,
/// because nothing invalidated the view that had already started it.
public struct DSReduceMotionGated: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let animation: Animation
    private let isActive: Bool

    public init(animation: Animation, isActive: Bool) {
        self.animation = animation
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : animation, value: isActive)
            // Re-evaluate when the accessibility setting itself flips, so a running animation stops
            // rather than outliving the preference that permitted it.
            .id(reduceMotion)
    }
}

extension View {
    /// Applies `animation` unless Reduce Motion is on. See ``DSReduceMotionGated``.
    public func dsReduceMotionGated(_ animation: Animation, isActive: Bool) -> some View {
        modifier(DSReduceMotionGated(animation: animation, isActive: isActive))
    }
}

// MARK: - Selected list row

/// The navigator's selected row: a lifted card, not a tint.
///
/// Two selections are live in this window at once — the navigator's endpoint and the request log's
/// row — and they must not compete, because the one the user is actually tracking is the log's. So
/// they are deliberately different mechanisms: the log takes an accent wash plus a 3pt rail, and the
/// navigator takes elevation.
///
/// Elevation here means all three of fill, hairline and shadow. The fill alone is not enough in dark,
/// where `surfaceElevated` and `surfacePanelHeader` are the same value on purpose — there, the shadow
/// and the border *are* the selection.
public struct DSSelectedListRow: ViewModifier {
    private let isSelected: Bool

    public init(isSelected: Bool) {
        self.isSelected = isSelected
    }

    public func body(content: Content) -> some View {
        content
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: DSCornerRadius.mdPlus)
                        .fill(DSColors.surfaceElevated)
                        .overlay {
                            RoundedRectangle(cornerRadius: DSCornerRadius.mdPlus)
                                .stroke(DSColors.border, lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                }
            }
    }
}

extension View {
    /// Marks a navigator row as selected. See ``DSSelectedListRow``.
    public func dsSelectedListRow(_ isSelected: Bool) -> some View {
        modifier(DSSelectedListRow(isSelected: isSelected))
    }
}

// MARK: - Segmented progress

/// A journey's progress as one segment per step.
///
/// **Segments are filled by `isExhausted`, never "up to the cursor".** That distinction is the whole
/// reason this is a shared component rather than three hand-rolled bars: under the default
/// `orderedPerEndpoint` match mode the resolver scans *forward* from the cursor, so step 4 can have
/// answered while the cursor still sits on step 2. The handoff specifies "filled up to the cursor",
/// and its own illustration is captioned "Cursor on step 2 of 4 · 3 responses served" — which that
/// rule would draw as one segment of four.
///
/// Three surfaces show this same value — the toolbar chip, the navigator's active-journey card and
/// the inspector's Overview card — so a second implementation would be a second answer to the same
/// question.
public struct DSProgressSegments: View {
    private let states: [Bool]
    private let height: CGFloat
    private let identifier: String

    /// - Parameter states: one entry per step, `true` when that step has been exhausted.
    public init(states: [Bool], height: CGFloat = 3, identifier: String) {
        self.states = states
        self.height = height
        self.identifier = identifier
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(states.enumerated()), id: \.offset) { pair in
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(pair.element ? DSColors.Journey.accent : DSColors.Journey.accent.opacity(0.22))
                    .frame(height: height)
            }
        }
        .accessibilityElement()
        .accessibilityIdentifier(identifier)
        // One spoken value, not N unlabelled bars. VoiceOver reading "filled, filled, empty, filled"
        // is a description of the drawing rather than of the journey.
        .accessibilityLabel("Journey progress")
        .accessibilityValue("\(states.filter { $0 }.count) of \(states.count) steps served")
    }
}
