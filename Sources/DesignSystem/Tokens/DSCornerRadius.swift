import SwiftUI

/// Corner radius tokens.
///
/// The rungs are a ladder, not a palette: a control asks for the tier it belongs to, and the tier is
/// decided by what the control *is* rather than by how round someone wanted it that day.
///
/// **The tier is a function of the control's height.** That is the rule the redesign made explicit
/// and it is worth stating, because it is what stops this scale drifting: a 15pt badge takes ``sm``,
/// a 21–22pt control in a panel header takes ``smPlus``, a 24pt control takes ``md``, a 28–30pt
/// control in an editor row takes ``mdPlus``, a toolbar segment or an input group takes ``lg``, and a
/// card takes ``lgPlus``. Radius scales with the box or the corners stop looking like they belong to
/// the same family.
public enum DSCornerRadius {
    /// 3pt — the smallest tier, for a mark rather than a control: a status dot, a copy chip, an
    /// inline swatch inside a row of text.
    ///
    /// The redesign proposed retiring this and folding it into ``sm``. It survives because nine call
    /// sites use it and they are all genuinely sub-badge marks, where 4pt reads as a rounded square
    /// rather than a dot. Do not reach for it on anything with a hit target.
    public static let xs: CGFloat = 3

    /// 4pt — method badges, status swatches, small tinted pills. Anything 14–16pt tall.
    public static let sm: CGFloat = 4

    /// 5pt — a control inside a 30pt panel header: a tab pill, a mode-rail item, a header button, a
    /// filter field. All of those are 21–22pt tall, and this is the tier that keeps them reading as
    /// one row rather than four separately-drawn objects.
    public static let smPlus: CGFloat = 5

    /// 6pt — a 24pt control: a segmented item, a small button, a run-bar action.
    public static let md: CGFloat = 6

    /// 7pt — a 28–30pt control in an editor row, and a navigator list row. Big enough that the
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
