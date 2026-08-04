import SwiftUI

/// Spacing scale tokens — tighter for professional dev-tool density.
public enum DSSpacing {
    /// 2pt — tight inline gaps, micro adjustments
    public static let xxs: CGFloat = 2
    /// 4pt — icon gaps, inline label-icon padding
    public static let xs: CGFloat = 4
    /// 6pt — compact element spacing, form field row gaps
    public static let sm: CGFloat = 6
    /// 12pt — default element spacing, panel content padding
    public static let md: CGFloat = 12
    /// 16pt — section padding, dialog body padding
    public static let lg: CGFloat = 16
    /// 24pt — layout gaps between major panes
    public static let xl: CGFloat = 24
    /// 32pt — major section breaks, empty-state vertical rhythm
    public static let xxl: CGFloat = 32
    /// 48pt — page-level spacing, welcome window padding
    public static let xxxl: CGFloat = 48
}
