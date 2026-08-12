import CoreGraphics

/// The heights a control is allowed to be, and the padding that produces them.
///
/// `DSBarHeight` names the rungs a *bar* stands on. Nothing named the rungs a *control* stands on,
/// and the house rule says controls sharing a row share their geometry — "height, corner radius,
/// border weight and vertical padding come from one place, not from four independently written call
/// sites". There were six places. `DSButtonSize`, `DSTextField`, `DSFilterField` and `DSStatusBadge`
/// each declared the ladder privately, and `RequestLogDrawerView.HeaderControl` and
/// `EndpointEditorView.EditorField` declared it again in a different module — the first with a
/// comment noting it matches `DSFilterField` "so a panel that later adopts that component does not
/// change shape on the way in". That is a cross-module coupling asserted in prose, kept true by hand,
/// and checked by nothing.
///
/// Naming the rungs changes no pixel: all six already agreed. It means the seventh control starts
/// from a list rather than from whatever its neighbour happened to measure.
public enum DSControlHeight {
    /// 20 — a control that sits in a row of other controls: panel-header controls, badges, filter
    /// fields, small buttons. The rung `DSBarHeight.controlRow` is built from (20 + `sm` above and
    /// below).
    public static let row: CGFloat = 20

    /// 22 — a control a user types into, or a single prominent action in a header. A 13pt line with
    /// ``verticalPadding`` above and below.
    public static let field: CGFloat = 22

    /// 28 — the one-per-sheet primary action.
    public static let prominent: CGFloat = 28

    /// 3 — the inset above and below a control's own text. Half of `DSSpacing.sm`, which is why it is
    /// not on the spacing scale: it is a control's internal geometry, not a gap between two things.
    public static let verticalPadding: CGFloat = 3
}

/// The two line weights this window draws.
///
/// A hairline and a seam. `DSDivider` already encodes which colour goes with which — `border` and
/// `separator` at ``hairline``, `panelSeparator` at ``seam`` — and explains why two of the three used
/// to be indistinguishable. The *weights* were still written as bare literals in twenty-one places:
/// ten strokes, seven closing rules under a bar, three private constants, and
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
