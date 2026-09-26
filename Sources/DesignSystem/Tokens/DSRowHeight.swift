import CoreGraphics

/// Shared row heights for content lists. Rows have enough room for the text that people scan;
/// shorter group labels and table chrome use separate bar metrics.
public enum DSRowHeight {
    /// 34pt — a navigator row with a method badge, path, and metadata.
    public static let listRow: CGFloat = 34

    /// 32pt — a request log row with seven aligned columns.
    public static let logRow: CGFloat = 32

    /// 30pt — an import candidate with a method, path, status, and flag.
    public static let importRow: CGFloat = 30

    /// 22pt — a navigator group label.
    public static let groupHeader: CGFloat = 22

    /// 30pt — a scenario row or another compact name-and-status row.
    public static let compactRow: CGFloat = 30

    /// 60pt — a two-line journey step with name, route, and outcome.
    public static let journeyStep: CGFloat = 60
}
