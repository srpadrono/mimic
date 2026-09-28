import CoreGraphics

/// Heights for the window's chrome. Sidebar, content, and inspector all start 44pt from the top.
public enum DSBarHeight {
    /// 44pt — the toolbar, and each column's header.
    public static let column: CGFloat = 44
    /// 30pt — the jump bar, the only bar under the toolbar.
    public static let jumpBar: CGFloat = 30
    /// 40pt — a pane header with a title and filters, like the request log's.
    public static let paneHeader: CGFloat = 40
    /// 44pt — the sidebar's filter footer.
    public static let footer: CGFloat = 44
}
