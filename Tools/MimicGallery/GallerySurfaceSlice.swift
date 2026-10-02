import DesignSystem
import SwiftUI

/// The window's content surface around a slice of it, for an entry whose artboard rect takes in the
/// surface's edges: its hairline border on the sides (and the top, with its rounded corners, for the
/// slice at the top of the surface), drawn as `WorkspaceShellLayout` draws the whole surface.
///
/// Only the edges the slice reaches are drawn: the border runs on past the bottom of the slice, and
/// past its top as well when the slice starts below the surface's top.
struct GallerySurfaceSlice: ViewModifier {
    /// Whether the slice starts at the surface's top edge.
    let includesTop: Bool

    func body(content: Content) -> some View {
        let radius = DSCornerRadius.panel
        content
            .background(DSColors.content)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: includesTop ? radius : 0,
                                              topTrailingRadius: includesTop ? radius : 0,
                                              style: .continuous))
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    // Taller than the slice by a corner's height at each open end, so the curve of
                    // a corner the slice does not reach falls outside it.
                    let overhang = radius * 2
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
                        .frame(width: proxy.size.width,
                               height: proxy.size.height + overhang * (includesTop ? 1 : 2))
                        .offset(y: includesTop ? 0 : -overhang)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .clipped()
            // The window behind the surface shows in the rounded corners, as on the artboard.
            .background(DSColors.window)
    }
}

extension View {
    /// Draws the content surface's edges around a slice of it; see ``GallerySurfaceSlice``.
    func gallerySurfaceSlice(includesTop: Bool) -> some View {
        modifier(GallerySurfaceSlice(includesTop: includesTop))
    }
}
