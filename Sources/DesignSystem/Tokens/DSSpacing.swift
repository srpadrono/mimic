import CoreGraphics

/// A 4pt grid. Prefer the nearest step; add a step only for a recurring layout need.
public enum DSSpacing {
    /// 2pt — hairline adjustments inside a control.
    public static let xxs: CGFloat = 2
    /// 4pt — between a glyph and its label, between list rows.
    public static let xs: CGFloat = 4
    /// 8pt — between related controls, a row's side inset, the window's panel inset.
    public static let sm: CGFloat = 8
    /// 12pt — between groups of controls, a panel's side inset.
    public static let md: CGFloat = 12
    /// 16pt — an inspector's side inset, between sections.
    public static let lg: CGFloat = 16
    /// 20pt — an editor's side inset, a sheet's padding.
    public static let xl: CGFloat = 20
    /// 24pt — between major blocks.
    public static let xxl: CGFloat = 24
    /// 32pt — page-level rhythm in the welcome window and empty states.
    public static let xxxl: CGFloat = 32
}
