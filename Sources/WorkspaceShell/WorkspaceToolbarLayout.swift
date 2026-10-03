import CoreGraphics
import DesignSystem

/// How much of the workspace toolbar fits over the centre column.
///
/// Collapse in stages as the centre column narrows: first import, server settings and the panel
/// toggles fold into one menu, then the server line drops its counts, the address its port count
/// and divider, and the project name its subtitle, then the project name narrows, and last Run/Stop
/// folds into the same menu. The address and the state word always stay.
///
/// The last breakpoint is what the narrow tier needs: Run, the name (≤100pt), the address
/// without its port count and the state, and "More", plus the toolbar's gaps and the column's
/// insets. A 900pt window with both side panels open leaves about 330pt: enough for a short
/// project name, but a longer one pushed "More" behind AppKit's own chevron there, so Run
/// folds below 360pt, where every name fits.
public nonisolated enum WorkspaceToolbarLayout: Equatable, Sendable {
    case expanded
    /// The server line keeps only its state word, the address drops its port count and divider, and
    /// the project name drops its subtitle: the design's compact centre column.
    case compactSummary
    case overflow
    /// The project identity narrows too.
    case narrow
    /// Run/Stop joins the "More actions" menu too, so the identity, the address and that one menu
    /// are all the toolbar holds and nothing ever reaches AppKit's own overflow chevron.
    case minimal

    /// Each trailing action's width in its glass group, as the design draws it: wider than the
    /// toolbar's own icon buttons.
    public static let actionWidth: CGFloat = 50

    public init(centerWidth: CGFloat) {
        guard centerWidth.isFinite else { self = .minimal; return }
        if centerWidth < Self.minimalCenterWidth { self = .minimal }
        else if centerWidth < 460 { self = .narrow }
        else if centerWidth < 620 { self = .compactSummary }
        else if centerWidth < 780 { self = .overflow }
        else { self = .expanded }
    }

    public var usesCompactSummary: Bool {
        switch self {
        case .compactSummary, .narrow, .minimal: true
        case .expanded, .overflow: false
        }
    }

    /// Import, server settings, and the panel toggles (while the inspector is hidden) move into one
    /// menu; Run joins them only in the minimal tier (`foldsRun`).
    public var usesOverflow: Bool { self != .expanded }

    public var usesNarrowIdentity: Bool { self == .narrow || self == .minimal }

    /// Run/Stop leads the "More actions" menu instead of the toolbar.
    public var foldsRun: Bool { self == .minimal }

    /// The narrowest centre column the minimal tier fits over.
    public static let minimalCenterWidth: CGFloat = 360

    /// What the window's own controls, the traffic lights and the sidebar button, take from the
    /// front of the centre column's toolbar while the navigator is hidden and they sit over it.
    public static let leadingWindowChrome: CGFloat = 144

    /// The narrowest the window may get, whatever is open.
    ///
    /// A navigator at its widest and a detail column of 320pt — enough for the minimal tier's toolbar
    /// (the identity, the address and "More") and the editor's fixed controls. A hidden navigator
    /// leaves the window's own controls over the column, and 680pt still gives them and the minimal
    /// tier their room. With the inspector open the window's own minimum is wider than this anyway.
    public static let minimumWindowWidth: CGFloat = DSLayout.sidebarMaximumWidth + minimumDetailWidthBesideNavigator

    /// The detail column's floor while the navigator is shown.
    public static let minimumDetailWidthBesideNavigator: CGFloat = 320

    /// Whether the inspector can be open beside the navigator and still leave the centre column room
    /// for its editor and a toolbar that stays out of AppKit's overflow chevron.
    ///
    /// With the navigator hidden the window's own controls sit over the centre column, so the column
    /// needs the minimal tier and those controls. Beside a navigator it needs
    /// ``minimumDetailWidthBesideNavigator`` once the navigator has given up all it can, down to its
    /// own minimum. Without room the side panel gives way rather than the toolbar, and comes back when
    /// the window widens. Opening it in a window too narrow used to push the navigator off the
    /// window's leading edge, because the window does not grow for it.
    ///
    /// Judged on the window's width and the panels' fixed sizes rather than on anything measured
    /// inside the window, so neither closing the inspector nor the navigator giving way to it can make
    /// room that would flip the answer back.
    public static func leavesRoomForInspector(
        windowWidth: CGFloat, inspectorWidth: CGFloat, isNavigatorHidden: Bool
    ) -> Bool {
        guard windowWidth.isFinite else { return true }
        if isNavigatorHidden {
            return windowWidth - inspectorWidth >= minimalCenterWidth + leadingWindowChrome
        }
        return windowWidth - DSLayout.sidebarMinimumWidth - inspectorWidth >= minimumDetailWidthBesideNavigator
    }

    /// The project identity's widest extent at each stage, so the centre column's items fit its section.
    public var projectIdentityMaximumWidth: CGFloat {
        switch self {
        case .expanded, .overflow: 220
        case .compactSummary: 140
        case .narrow, .minimal: 100
        }
    }
}
