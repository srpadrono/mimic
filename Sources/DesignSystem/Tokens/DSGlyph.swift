import CoreGraphics

/// The sizes a glyph in the window's chrome is allowed to be drawn at.
///
/// `DSBarHeight` names the rungs a bar stands on and `DSControlHeight` the rungs a control stands on.
/// The house rule names a third ladder and always has — "No glyph below 8pt. Separators and menu
/// indicators are 8pt, inline glyphs 9–10pt, control glyphs 11–13pt" — and it was the one design rule
/// in this repository stated as an explicit numeric ladder with nothing behind it. It was spelled as
/// bare `.font(.system(size:))` literals in thirty-odd places across two modules, so every one of
/// those numbers had to be reverse-engineered from whatever it happened to sit beside, and the ladder
/// existed only in prose that nothing could check.
///
/// **The floor is the part worth naming twice.** A glyph below 8pt does not read as small, it reads
/// as dirt on the screen — decoration that happens to be load-bearing. `DSFilterField`'s scope pill
/// is the case that proves it: while unscoped the pill carries no title, so its chevron is the only
/// thing on screen saying the pill opens anything, and a mark too small to resolve means the scope is
/// never discovered. So ``minimum`` is stated alongside ``indicator`` even though the two are the same
/// number, exactly as `DSStroke` names `seam` and `focusRing` separately: one is a size to draw at,
/// the other is a bound to check against, and a test can only pin a bound that has a name.
///
/// **These rungs come in tiers rather than as four flat points**, because the rule states ranges
/// rather than values. Within a tier the choice is usually made for you by the text the glyph sits
/// beside: 10, 11 and 13 are exactly the sizes of `DSTypography.caption`, `.label` and `.body`, so a
/// glyph next to a line of type matches that line instead of standing a point proud of it. 9 and 12
/// answer to no type size, and are the quiet and loud ends of their tiers.
///
/// **An illustration is not a glyph and does not belong here.** `DSEmptyState` draws its symbol at
/// 26pt and the welcome window's first-run clock matches it deliberately. Those are pictures sized to
/// the panel they fill; folding them in would turn a ladder with a defensible top rung into an
/// open-ended scale, so they stay named constants on the views that own them. A *chrome* glyph above
/// ``controlProminent`` is a different matter and is off the ladder rather than exempt from it — the
/// welcome window's 14pt action glyphs are the one such site. They are still 14: the adoption pass
/// left them alone and said why at the call site, because moving a glyph on the first screen a new
/// user sees is a visual decision rather than a mechanical substitution.
///
/// Naming the rungs changes no pixel — every value below is one already in the window. What it
/// changes is that the next glyph starts from a list of six rather than from whatever its neighbour
/// happened to measure.
///
/// **Both modules now draw from it.** `AppFeatures` had two dozen `.font(.system(size:))` literals
/// and not one reference to this type. Exactly two of those literals are left — the welcome window's
/// 14pt action glyph named above, and its 26pt first-run clock, which is an illustration — and each
/// says at its call site which of the two it is. Anything else is a regression, and
/// `grep -rn '\.font(\.system(size: [0-9]' Sources` is the whole check.
public enum DSGlyph {
    /// 8 — a mark that annotates something else and never speaks on its own: a menu's disclosure
    /// indicator, a separator between two crumbs, a state dot.
    ///
    /// `DSFilterField`'s `chevron.up.chevron.down`, the breadcrumb bar's crumb chevrons and the
    /// `chevron.right` between them, and the autosave checkmark all stand here. This is the bottom of
    /// the ladder — see ``minimum``.
    public static let indicator: CGFloat = 8

    /// 9 — the quiet end of the inline tier: a glyph that qualifies a control rather than labelling
    /// it. The filter glyph inside `DSFilterField`'s scope pill, a column header's sort chevron, the
    /// warning triangle in the server well.
    ///
    /// Deliberately below ``inline`` and not on a type size. A glyph at 10 beside an 11pt title reads
    /// as a second piece of content; at 9 it reads as an annotation on the first.
    public static let inlineSmall: CGFloat = 9

    /// 10 — a glyph on a line of text, at `DSTypography.caption`'s size. `DSTextField`'s and
    /// `DSJSONEditor`'s validation marks, and the glyph `DSButton(.small)` puts before its title.
    ///
    /// The validation cases are why the tier exists at all: a red message is one channel of meaning,
    /// and the glyph is the half that survives Differentiate Without Color, a greyscale screenshot
    /// and a red deficiency. A mark carrying that much has to be legible, which is what puts it a tier
    /// above ``indicator``.
    public static let inline: CGFloat = 10

    /// 11 — a glyph that *is* the control, at `DSTypography.label`'s size. `DSPanelHeaderButton`,
    /// `DSClearButton`, and `DSButton(.medium)`'s glyph.
    ///
    /// The bottom of the control tier rather than the top of the inline one: these have no title
    /// beside them, so the glyph is the whole affordance and has to be found by someone who is not
    /// already looking at it.
    public static let control: CGFloat = 11

    /// 12 — a control glyph that carries a row on its own: `DSButton(.large)`'s marker on the
    /// one-per-sheet primary action, and the server toggle, which is the window's primary action.
    ///
    /// Between two type sizes, and that is what it is for: a control that has to outrank the header
    /// buttons at ``control`` without reading as a navigator tab at ``controlProminent``. The server
    /// toggle drops to ``inline`` while it is transitioning, which is the one glyph in the window that
    /// deliberately changes rung to say something.
    public static let controlLarge: CGFloat = 12

    /// 13 — the largest a chrome glyph goes, at `DSTypography.body`'s size. `DSTabStrip`'s navigator
    /// tabs, where the icon replaces a word rather than accompanying one, and `DSIconMenu`, which is
    /// what the editor's more menu and the journeys navigator's "+" are.
    ///
    /// The ceiling is as load-bearing as the floor. A strip of icon-only tabs is only affordable
    /// because the icons stay legible where two or three text segments would truncate on the first
    /// long noun, and that trade stops paying the moment a glyph grows past the line of body text it
    /// stands in for.
    public static let controlProminent: CGFloat = 13

    /// 8 — the floor the house rule states, named so it can be cited and asserted rather than
    /// remembered. **Not a size to draw at**: reach for ``indicator``, which is the same number
    /// answering the question "how big is a menu indicator" instead of "how small may anything be".
    ///
    /// Same split, and the same reason, as `DSStroke.seam` and `DSStroke.focusRing`.
    public static let minimum: CGFloat = 8
}
