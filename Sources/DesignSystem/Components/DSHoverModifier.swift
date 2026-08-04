import SwiftUI

/// The hover highlight a list row wears: the accent tint every other control in the design system
/// lights up with, and nothing else.
///
/// **It no longer scales.** The row grew by 0.4% under the pointer, and two things were wrong with
/// that. A 0.4% scale is sub-pixel, so its entire visible effect is resampling the row's text — the
/// row does not look bigger, it looks briefly out of focus. And it is motion, in a modifier applied
/// to four different lists, which made it the last place in the app where pointing at something moved
/// it. `DSButton` removed its own hover scale for the same reason: AppKit controls do not change size
/// when you point at them, they change colour. With the scale gone the remaining change is a
/// cross-fade, which is what Reduce Motion asks for rather than something it has to suppress.
///
/// **The duration is a token.** It was a hard-coded `0.12` — twice `DSAnimation.micro`, which is what
/// `DSTabStrip`, `DSPanelHeaderButton`, `DSFilterField`'s clear button and the request log's rows all
/// use — so a row lit up visibly more slowly than a button sitting inside it.
public struct DSHoverHighlight: ViewModifier {
    @State private var isHovered = false
    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = DSCornerRadius.sm) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovered ? DSColors.accentSubtle : Color.clear)
            }
            // The whole rounded rect is the hover region, not just the glyphs inside it. An unfilled
            // shape is not hit-testable — the correction `DSButton`'s ghost variant needed — so on the
            // two call sites that do not set their own content shape, a row only lit up while the
            // pointer was over a word and flickered off in the gaps between them.
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
    }
}

extension View {
    /// Adds the design system's accent-tinted hover background, matched to the row's own shape.
    public func dsHoverHighlight(cornerRadius: CGFloat = DSCornerRadius.sm) -> some View {
        modifier(DSHoverHighlight(cornerRadius: cornerRadius))
    }
}
