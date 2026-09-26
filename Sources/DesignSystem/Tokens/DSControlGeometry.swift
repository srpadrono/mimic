import CoreGraphics

/// Shared control heights and internal padding. Controls in the same row use the same tier.
public enum DSControlHeight {
    /// 24pt — small buttons and compact row controls.
    public static let row: CGFloat = 24

    /// 26pt — fields and single header actions.
    public static let field: CGFloat = 26

    /// 30pt — search fields and icon-and-title navigation targets.
    public static let search: CGFloat = 30
    public static let navigation: CGFloat = 30

    /// 32pt — the one-per-sheet primary action.
    public static let prominent: CGFloat = 32

    /// 3 — the inset above and below a control's own text. Half of `DSSpacing.sm`, which is why it is
    /// not on the spacing scale: it is a control's internal geometry, not a gap between two things.
    public static let verticalPadding: CGFloat = 3
}

/// Shared stroke widths in points. A 0.5pt hairline is one physical pixel at 2× scale
/// and subpixel on a 1× display; the 1pt seam emphasizes panel boundaries.
public enum DSStroke {
    /// 0.5 — a border, a well's edge, the rule that closes a bar. One device pixel at 2×.
    public static let hairline: CGFloat = 0.5

    /// 1 — the seam between two panels, which has to read as a boundary rather than a row divider.
    public static let seam: CGFloat = 1

    /// 1 — the ring drawn around a focused control. Same weight as a seam, and named separately
    /// because it answers a different question: this one is a state, not a boundary.
    public static let focusRing: CGFloat = 1
}

/// Stable summary geometry; native toolbar groups own their action surfaces.
nonisolated public enum DSToolbarGeometry {
    /// Matches the native macOS sidebar toggle in the same toolbar.
    public static let height: CGFloat = 36
    public static let contentHeight: CGFloat = 16
    /// The full project and server summaries need this much centre-column space beside the actions.
    public static let expandedCenterWidth: CGFloat = 600
    /// The shorter summaries keep both editor actions visible until the centre gets this narrow.
    public static let actionOverflowCenterWidth: CGFloat = 440
    /// Below this width, a status icon keeps the project identity in the native toolbar.
    public static let iconStatusCenterWidth: CGFloat = 380
    public static let projectTitleWidth: CGFloat = 160
    public static let compactProjectTitleWidth: CGFloat = 120
    public static let metadataHeight: CGFloat = 12
    public static let detailsWidth: CGFloat = 340
    public static let detailsListHeight: CGFloat = 320
    public static let copyButtonWidth: CGFloat = 100
    public static let compactStatusWidth: CGFloat = 104
    public static let iconStatusWidth: CGFloat = height
    public static let statusWidth: CGFloat = 220
}
