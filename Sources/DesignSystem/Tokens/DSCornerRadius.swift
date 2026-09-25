import SwiftUI

/// Corner radius tokens.
///
/// The rungs are a ladder, not a palette: a control asks for the tier it belongs to, and the tier is
/// decided by what the control *is* rather than by how round someone wanted it that day.
///
/// **Radius follows the size and role of its surface.** Method badges and compact wells take ``sm``;
/// mode-rail and scenario controls take ``smPlus``; larger buttons and editor groups use the middle
/// tiers; a toolbar segment or input group takes ``lg``, and a card takes ``lgPlus``. Keeping that
/// relationship is what makes the corners look like one family as the control heights change.
public enum DSCornerRadius {
    /// 3pt — the smallest tier, for a mark rather than a control: a status dot, a copy chip, an
    /// inline swatch inside a row of text.
    ///
    /// The redesign proposed retiring this and folding it into ``sm``. It survives because nine call
    /// sites use it and they are all genuinely sub-badge marks, where 4pt reads as a rounded square
    /// rather than a dot. Do not reach for it on anything with a hit target.
    public static let xs: CGFloat = 3

    /// 4pt — method badges, status swatches, small tinted pills, and compact wells.
    public static let sm: CGFloat = 4

    /// 5pt — compact mode and scenario controls, which share the 24pt row-control height.
    public static let smPlus: CGFloat = 5

    /// 6pt — larger buttons and segmented controls.
    public static let md: CGFloat = 6

    /// 7pt — an editor-row group or navigator list row. Big enough that the
    /// corner is visible at a glance, small enough that the row still reads as a row.
    public static let mdPlus: CGFloat = 7

    /// 8pt — a toolbar segment, an input group, a bordered container holding other controls.
    public static let lg: CGFloat = 8

    /// 10pt — a card: an inspector card, a template card, an empty-state card. The tier that says
    /// "this is a surface with its own shadow", not "this is a control".
    public static let lgPlus: CGFloat = 10

    /// 12pt — modals, welcome cards.
    public static let xl: CGFloat = 12
}
