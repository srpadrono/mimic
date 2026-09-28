import CoreGraphics

/// Corner radii. Controls and rows use ``field``, containers ``panel``, sheets ``sheet``; buttons are
/// capsules and need no token.
public enum DSCornerRadius {
    /// 4pt — marks inside a row: a checkbox, a chart bar.
    public static let mark: CGFloat = 4
    /// 7pt — fields, list rows, pop-up buttons.
    public static let field: CGFloat = 7
    /// 8pt — a segmented control's track.
    public static let segment: CGFloat = 8
    /// 10pt — code wells, banners, cards inside a pane.
    public static let card: CGFloat = 10
    /// 12pt — the content surface and popovers.
    public static let panel: CGFloat = 12
    /// 20pt — sheets.
    public static let sheet: CGFloat = 20
}
