import SwiftUI

/// Visual emphasis for dividers.
///
/// Each case names a colour token rather than multiplying one, because the two that multiplied were
/// the two that did not work. See ``DSDivider``.
public enum DSDividerStyle {
    /// A hairline at `DSColors.border` — the weight the design system draws around a well. For rules
    /// inside a panel, between closely related rows.
    case subtle
    /// A hairline at `DSColors.separator` — the default section separator.
    case standard
    /// 1pt at `DSColors.panelSeparator` — the seam *between* two panels, and nothing else.
    ///
    /// Deliberately not what a bar ends with. Horizontal bar bottoms all close at `.standard`
    /// (12%): they were split between this token and that one depending on whether the author
    /// reached for an overlay or for `DSDivider`, and the split tracked nothing — the request
    /// detail's identity row closed lighter than a section header nested inside it.
    case strong
}

/// Clean, precise separator.
///
/// The three styles have to be tellable apart, and two of them were not.
///
/// `.subtle` was `DSColors.separator.opacity(0.4)`. `separator` is 12% alpha, so that lands at
/// **4.8%** — a rule you cannot see on any surface in the app. It is the same mistake
/// `DSSectionHeader` made with `separator.opacity(0.6)` (~7%) and corrected for the same reason, and
/// it meant the import review's summary rule and the request detail's section rules were simply
/// absent while the code claimed to draw them.
///
/// `.strong` drew the *same colour* as `.standard` and differed only by half a point of thickness.
/// At 12% alpha that is not a difference anybody can name, so "between major panels" and "default
/// section separator" rendered as the same line.
///
/// The ladder is now 9–10% → 12% → 14%, one token each, and the three read as three. The top rung
/// is 14 rather than 20 because Xcode's own panel seams measure 11.9–14.2% white on screen, and 20
/// read as a ruled form beside them.
public struct DSDivider: View {
    private let style: DSDividerStyle
    private let axis: Axis
    private let identifier: String

    public init(style: DSDividerStyle = .standard, axis: Axis = .horizontal, identifier: String = "default") {
        self.style = style
        self.axis = axis
        self.identifier = identifier
    }

    public var body: some View {
        Rectangle()
            .fill(style.color)
            .frame(
                width: axis == .vertical ? style.thickness : nil,
                height: axis == .horizontal ? style.thickness : nil
            )
            .accessibilityIdentifier("ds.divider.\(identifier)")
    }
}

// MARK: - Geometry

private extension DSDividerStyle {
    /// A token, never a token times a number. An opacity applied on top of an alpha-bearing colour
    /// compounds into a value nobody has looked at — which is exactly how `.subtle` ended up at 4.8%.
    var color: Color {
        switch self {
        case .subtle: DSColors.border
        case .standard: DSColors.separator
        case .strong: DSColors.panelSeparator
        }
    }

    /// Hairlines for the in-panel styles; a full point only for the panel edge, where the rule is
    /// separating two surfaces rather than two groups of rows.
    var thickness: CGFloat {
        switch self {
        case .subtle, .standard: DSStroke.hairline
        case .strong: DSStroke.seam
        }
    }
}
