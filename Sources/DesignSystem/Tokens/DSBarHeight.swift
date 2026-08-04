import CoreGraphics

/// The heights a horizontal bar of chrome is allowed to be.
///
/// The window had ten. Two were declared — `DSPanelHeader.height` (30) and `BreadcrumbJumpBar.height`
/// (24) — and the rest were emergent: a `.padding(.vertical, sm)` wrapped around whatever AppKit's
/// `.controlSize(.small)` happened to measure, or a bare `22` written twice in two files. Nobody
/// chose 31, or 34, or 46; they fell out of other decisions, and a reader could not tell which
/// numbers were load-bearing.
///
/// Naming them does not change a single pixel. It makes the ladder legible, and it means the next
/// bar starts from a list of four rungs rather than from whatever its neighbour happened to be.
public enum DSBarHeight {
    /// 30 — the panel header tier. Sidebar chrome, panel headers, editor headers, the copy bar.
    ///
    /// The number lives here rather than on `DSPanelHeader`, which now reads it back. A component
    /// owning the rung meant every other bar in the window had to spell `DSPanelHeader<EmptyView>.height`
    /// to stand at it — naming a generic parameter it has no interest in, to borrow a number from a
    /// view it is not using. The ladder is the thing a bar consults; the header is one of its callers.
    public static let panelHeader: CGFloat = 30

    /// 24 — secondary chrome that sits *inside* a pane rather than above one. The breadcrumb jump
    /// bar, which would read as a fourth panel header at 30, and `DSSectionHeader` when it carries no
    /// trailing action. With one it grows to ``controlRow``, because the action is a 22pt control.
    public static let secondaryBar: CGFloat = 24

    /// 32 — a row of small controls: 20pt controls with `DSSpacing.sm` above and below.
    ///
    /// The journey editor's behaviour row, the journey run-controls row and the request detail's
    /// segmented picker row all stand here — a small popup, a `DSButton(.small)` and a small segmented
    /// control are each 20. Two of the three take it as a floor rather than a fixed height, because
    /// they fold to a second line when the pane is narrow: a fixed height would hold the folded layout
    /// at one row's worth of space and let it draw over whatever is underneath.
    public static let controlRow: CGFloat = 32

    /// 22 — a column-header strip above a table. Quieter than a panel header because it labels
    /// columns rather than naming the panel, which is `DSColors.band`'s job rather than this one's.
    public static let columnHeader: CGFloat = 22
}
