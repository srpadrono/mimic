import SwiftUI

/// Spacing scale tokens — tighter than a stock scale, for dev-tool density.
///
/// **The scale had a hole between 6 and 12, and the redesign kept falling into it.** Its stated
/// paddings include 8, 9, 10 and 11 — four numbers for what is really one tier, drawn slightly
/// differently each time in a prototype where nothing enforced a scale. Rather than admit four new
/// rungs, two were added at ``smPlus`` (8) and ``mdMinus`` (10) and the rest snap:
///
/// | Design says | Token | Why |
/// |---|---|---|
/// | 8 | ``smPlus`` | exact |
/// | 9 | ``smPlus`` | a point is not a tier; 9 appears only as a card's internal padding |
/// | 10 | ``mdMinus`` | exact |
/// | 11 | ``mdMinus`` | ditto — 11 appears once, as a warning card's padding |
/// | 14 | ``mdPlus`` | exact |
/// | 20 | ``lgPlus`` | exact |
/// | 22 | ``lgPlus`` | 22 appears once, as an editor's side padding |
/// | 26 | ``xl`` | 26 appears once, as the journeys gallery's outer padding |
///
/// The general rule when a design hands you a number that is not here: if it is within a point of a
/// rung, take the rung. If it is two or more away and it recurs, it is a tier and belongs in this
/// file. If it is two or more away and appears once, it is a mistake in the drawing.
public enum DSSpacing {
    /// 2pt — tight inline gaps, micro adjustments
    public static let xxs: CGFloat = 2
    /// 4pt — icon gaps, inline label-icon padding
    public static let xs: CGFloat = 4
    /// 6pt — compact element spacing, form field row gaps
    public static let sm: CGFloat = 6

    /// 8pt — a dense row's side inset: a navigator endpoint row, a group header. The tier between a
    /// compact gap and a panel's own padding, and the one this scale was missing.
    public static let smPlus: CGFloat = 8

    /// 10pt — a card's internal gap, and the padding inside a small tinted card.
    public static let mdMinus: CGFloat = 10

    /// 12pt — default element spacing, panel content padding
    public static let md: CGFloat = 12

    /// 14pt — a panel's own side inset where 12 reads as tight against a card edge: the inspector's
    /// provenance line, the toolbar's gutters.
    public static let mdPlus: CGFloat = 14

    /// 16pt — section padding, dialog body padding, a dense table's side inset
    public static let lg: CGFloat = 16

    /// 20pt — an editor's top padding, where the first section label needs air under a header bar
    /// without reading as a gap.
    public static let lgPlus: CGFloat = 20

    /// 24pt — layout gaps between major panes, an editor's side padding
    public static let xl: CGFloat = 24
    /// 32pt — major section breaks, empty-state vertical rhythm
    public static let xxl: CGFloat = 32
    /// 48pt — page-level spacing, welcome window padding
    public static let xxxl: CGFloat = 48
}
