import SwiftUI

/// What a bar of chrome is sitting on, which decides whether it gets a fill at all.
///
/// A panel header used to take one colour everywhere. That works while every panel sits on the same
/// surface, and it stops working the moment two of them do not: `surfacePanelHeader` over
/// `surfaceContent` is a legible step, and over `surfaceSidebar` it measures **ΔL\* 0.30** — five
/// times fainter than the faintest band this palette has ever allowed. Two of the window's four
/// panel headers sit on the sidebar surface, so half the chrome would have been invisible in light
/// mode.
///
/// The fix is not a third colour. It is that a header on a sidebar-like host **has no fill**, and
/// the 0.5pt rule it already closes with does the whole job — which is exactly what
/// `NSTableHeaderView` does, and why an AppKit table header and its table measure the same white.
/// The tab pills and mode pills inside the bar carry the weight instead.
public enum DSSurfaceHost: Sendable {
    /// The bar sits over the editor canvas or a log body — the centre column.
    case content
    /// The bar sits over the navigator or the inspector. On macOS 26 that surface is usually the
    /// system material rather than a flat fill, which is a second reason not to paint over it.
    case sidebar

    /// The fill a bar of chrome takes on this host, or `nil` when it takes none.
    public var chromeFill: Color? {
        switch self {
        case .content: DSColors.surfacePanelHeader
        case .sidebar: nil
        }
    }
}
