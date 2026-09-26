import SwiftUI

/// Shared spacing scale for dense developer-tool layouts.
/// Prefer the nearest existing token; add a new tier only for a recurring layout need.
public enum DSSpacing {
    /// 2pt — tight inline gaps, micro adjustments
    public static let xxs: CGFloat = 2
    /// 4pt — icon gaps, inline label-icon padding
    public static let xs: CGFloat = 4
    /// 6pt — compact element spacing, form field row gaps
    public static let sm: CGFloat = 6

    /// 8pt — a dense row's side inset: a navigator endpoint row, a group header. Between a
    /// compact gap and a panel's own padding.
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
