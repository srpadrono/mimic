import CoreGraphics

/// Control heights. Controls in one row share a size.
nonisolated public enum DSControlHeight {
    /// 28pt — buttons and fields in sheets.
    public static let large: CGFloat = 28
    /// 24pt — buttons and fields in panels.
    public static let regular: CGFloat = 24
    /// 20pt — inline buttons inside a row or banner.
    public static let small: CGFloat = 20
    /// 32pt — the request field at the top of the editor, and toolbar capsules.
    public static let prominent: CGFloat = 32
}

/// Stroke widths. Every rule is a hairline; focus is drawn as a halo, not a heavier line.
nonisolated public enum DSStroke {
    /// 0.5pt — separators and field borders.
    public static let hairline: CGFloat = 0.5
    /// 1pt — a field's border while focused or invalid.
    public static let emphasis: CGFloat = 1
    /// 3.5pt — the focus halo around a field.
    public static let focusHalo: CGFloat = 3.5
}

/// Panel widths and the thresholds where the window's layout changes.
nonisolated public enum DSLayout {
    public static let sidebarWidth: CGFloat = 264
    public static let sidebarMinimumWidth: CGFloat = 220
    public static let sidebarMaximumWidth: CGFloat = 360
    public static let inspectorWidth: CGFloat = 300
    public static let inspectorMinimumWidth: CGFloat = 260
    public static let inspectorMaximumWidth: CGFloat = 480
    /// The gap between the window edge, the floating panels, and the content surface.
    public static let panelInset: CGFloat = 8
    /// Label column in the inspector's key-value rows.
    public static let inspectorLabelWidth: CGFloat = 104
    /// Label column in sheets.
    public static let sheetLabelWidth: CGFloat = 104
    /// The method column: fits DELETE and OPTIONS in SF Mono 11.
    public static let methodColumn: CGFloat = 52
    /// Below this toolbar width the secondary actions collapse into one menu.
    public static let toolbarCollapseWidth: CGFloat = 720
    /// Below this width the server status drops its request counts.
    public static let toolbarStatusCompactWidth: CGFloat = 560
    /// The server status popover.
    public static let popoverWidth: CGFloat = 320
    /// Maximum readable width of an empty state's message.
    public static let emptyStateTextWidth: CGFloat = 360
}
