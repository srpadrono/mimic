import SwiftUI

/// The hover highlight a list row wears: the neutral `DSColors.hover` fill, and nothing else.
///
/// **It does not scale.** A sub-pixel scale only resamples the row's text, and AppKit controls do not
/// change size when you point at them, they change colour. With no motion the change is a cross-fade,
/// which is what Reduce Motion asks for rather than something it has to suppress.
///
/// **The duration is a token.** `DSAnimation.fast`, the same one `DSPanelHeaderButton`,
/// `DSFilterField`'s clear button and the request log's rows use, so a row lights up at the same pace
/// as a button sitting inside it.
public struct DSHoverHighlight: ViewModifier {
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = DSCornerRadius.field) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isEnabled && isHovered ? DSColors.hover : Color.clear)
            }
            // The whole rounded rect is the hover region, not just the glyphs inside it. An unfilled
            // shape is not hit-testable — the correction `DSButton`'s ghost variant needed — so on the
            // two call sites that do not set their own content shape, a row only lit up while the
            // pointer was over a word and flickered off in the gaps between them.
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { isHovered = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
            .animation(.easeOut(duration: DSAnimation.fast), value: isHovered)
    }
}

extension View {
    /// Adds the design system's hover background, matched to the row's own shape.
    public func dsHoverHighlight(cornerRadius: CGFloat = DSCornerRadius.field) -> some View {
        modifier(DSHoverHighlight(cornerRadius: cornerRadius))
    }
}
