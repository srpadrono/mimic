import CoreGraphics

/// Shared heights for workspace chrome. Each rung seats the typography and controls it contains;
/// panel headers, rows of controls, and column labels keep distinct levels of emphasis.
public enum DSBarHeight {
    /// 44pt — navigator mode switch and creation control.
    public static let navigatorHeader: CGFloat = 44

    /// 48pt — navigator filter and status controls.
    public static let navigatorFooter: CGFloat = 48

    /// 36pt — panel and editor headers.
    public static let panelHeader: CGFloat = 36

    /// 28pt — secondary chrome inside a pane, including the breadcrumb bar.
    public static let secondaryBar: CGFloat = 28

    /// 36pt — 24pt row controls with 6pt above and below.
    public static let controlRow: CGFloat = 36

    /// 26pt — compact column labels above a table.
    public static let columnHeader: CGFloat = 26
}
