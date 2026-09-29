import CoreGraphics

/// One row height per kind of list.
nonisolated public enum DSRowHeight {
    /// 28pt — sidebar rows, scenario rows, inspector key-value rows.
    public static let list: CGFloat = 28
    /// 24pt — table rows and column headers.
    public static let table: CGFloat = 24
    /// 22pt — a sidebar group header.
    public static let groupHeader: CGFloat = 22
    /// 48pt — a journey step: a 22pt run node with room around it.
    public static let step: CGFloat = 48
    /// 44pt — a recent project in the welcome window.
    public static let recent: CGFloat = 44
}
