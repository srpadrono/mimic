import SwiftUI

/// Corner radius tokens — refined scale.
public enum DSCornerRadius {
    /// 3pt — very small elements (status dots, inline badges)
    public static let xs: CGFloat = 3
    /// 4pt — text fields, small badges
    public static let sm: CGFloat = 4
    /// 6pt — buttons, panels, status badges
    public static let md: CGFloat = 6
    /// 8pt — sheets, large cards
    public static let lg: CGFloat = 8
    /// 12pt — modals, welcome cards
    public static let xl: CGFloat = 12
}
