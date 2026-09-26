import CoreGraphics

/// The heights a control is allowed to be, and the padding that produces them.
///
/// `DSBarHeight` names the rungs a *bar* stands on. Nothing named the rungs a *control* stands on,
/// and the house rule says controls sharing a row share their geometry — "height, corner radius,
/// border weight and vertical padding come from one place, not from four independently written call
/// sites". There were five places. `DSButtonSize`, `DSTextField` and `DSFilterField` each declared
/// the ladder privately, and `RequestLogDrawerView.HeaderControl` and
/// `EndpointEditorView.EditorField` declared it again in a different module — the first with a
/// comment noting it matches `DSFilterField` "so a panel that later adopts that component does not
/// change shape on the way in". That is a cross-module coupling asserted in prose, kept true by hand,
/// and checked by nothing.
///
/// Extracting the rungs originally changed no pixel: all five already agreed. It means later sizing
/// changes move together, and a new control starts from the shared scale.
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

/// The two line weights this window draws.
///
/// A hairline and a seam. `DSDivider` already encodes which colour goes with which — `border` and
/// `separator` at ``hairline``, `panelSeparator` at ``seam`` — and explains why two of the three used
/// to be indistinguishable. The *weights* were written as bare literals in twenty-three places:
/// eleven strokes, eight closing rules under a bar, three private constants, and
/// `DSDividerStyle.thickness`.
///
/// A stroke weight is not a free parameter here. 0.5 is a device pixel on every display this app runs
/// on, and 1 is the deliberate step up for the one line that separates two panels rather than two
/// rows inside one.
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
