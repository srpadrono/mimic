import CoreGraphics

/// The heights a row of *content* is allowed to be.
///
/// Separate from ``DSBarHeight`` on purpose. That enum is a ladder of chrome — bars that sit above,
/// below or beside content — and its whole value is that a bar asks it for a number. Mixing row
/// metrics into it turns "what rung is this bar on?" into "which of these nine numbers is a bar and
/// which is a row?", which is the question the ladder existed to remove.
///
/// The redesign specifies three, and they are content, not chrome: a navigator row, a request log
/// row, and the group header between them.
public enum DSRowHeight {
    /// 30 — a navigator row: method badge, path, trailing meta.
    ///
    /// The same number as ``DSBarHeight/panelHeader`` and that is a coincidence worth naming, so
    /// nobody "deduplicates" them. A panel header is 30 because that is the smallest a row of 22pt
    /// controls can honestly be; a navigator row is 30 because a 15pt badge and a 12.5pt path need
    /// that much air. If either reason changes, only one number should move.
    public static let listRow: CGFloat = 30

    /// 28 — a request log row.
    ///
    /// Up from 26. The redesign raised it to seat a latency bar, and that feature was cut — but the
    /// extra two points were kept, because the row also gained a seventh column and 26 was already
    /// the tightest row in the window. This multiplies across a long log, so it is a deliberate cost:
    /// at the shipped 1000-entry cap it is 2,000 points of scroll, and roughly one fewer visible row
    /// at the drawer's default height.
    public static let logRow: CGFloat = 28

    /// 18 — a group-tag header in the navigator.
    ///
    /// Deliberately short. It names a section rather than being one, so it takes the smallest height
    /// that seats 11pt semibold without the text feeling wedged.
    public static let groupHeader: CGFloat = 18

    /// 26 — a scenario row in the inspector, and any list row that is a name plus a status rather
    /// than a badge plus a path.
    public static let compactRow: CGFloat = 26
}
