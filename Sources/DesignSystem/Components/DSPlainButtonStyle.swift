import SwiftUI

/// A plain control that answers the pointer **and** the press.
///
/// **Every `.buttonStyle(.plain)` in this app drew hover and nothing on press.** Twenty call sites,
/// not one of them reading `configuration.isPressed` — `SortableColumnHeader` even carries a comment
/// saying "a plain button gives no pressed state" and leaves it there. A control that lights up when
/// you point at it and then does nothing at all when you click is one you press twice, because the
/// first press left no evidence it landed.
///
/// A `ViewModifier` cannot fix it. ``DSHoverHighlight`` is the shared hover this replaces at button
/// call sites, and a modifier has no access to the press — only a `ButtonStyle` does, which is the
/// whole reason this type exists rather than another modifier.
///
/// The rest state is `.clear` rather than a zero-alpha tint, matching ``DSHoverHighlight``: rows and
/// buttons sit next to each other in these panels and must not disagree about what "not hovered"
/// looks like.
public struct DSPlainButtonStyle: ButtonStyle {
    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = DSCornerRadius.sm) {
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, cornerRadius: cornerRadius)
    }

    /// Hover state needs `@State`, and a `ButtonStyle` is not a `View`, so the tracking lives in a
    /// nested one. `DSButtonStyle` is built the same way for the same reason.
    private struct Surface: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(DSPlainButtonStyle.wash(isPressed: configuration.isPressed,
                                                      isHovered: isHovered))
                }
                // An unfilled shape is not hit-testable, so without this a control only lights up
                // while the pointer is over a glyph and flickers off in the gaps — the same
                // correction `DSHoverHighlight` and `DSButton`'s ghost variant both needed.
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
                .animation(.easeOut(duration: DSAnimation.micro), value: configuration.isPressed)
        }
    }

    /// The wash for a given state.
    ///
    /// Pressed is ``DSColors/accentMuted`` — the *existing* 25% rung — rather than a new alpha minted
    /// for this control. Hover is ``DSColors/accentSubtle`` at 12%, which is what every row in these
    /// panels already lights up with, so a button and the row beneath it agree.
    ///
    /// Exposed so a test can compare the three states without rendering: they have to be three
    /// distinguishable values, and "pressed is stronger than hover is stronger than rest" is the
    /// property, not any particular alpha.
    public static func wash(isPressed: Bool, isHovered: Bool) -> Color {
        if isPressed { return DSColors.accentMuted }
        return isHovered ? DSColors.accentSubtle : .clear
    }
}

extension ButtonStyle where Self == DSPlainButtonStyle {
    /// `.buttonStyle(.dsPlain)` — plain chrome that answers hover and press.
    public static var dsPlain: DSPlainButtonStyle { DSPlainButtonStyle() }

    /// The same, matched to a row or control whose corner is not ``DSCornerRadius/sm``.
    public static func dsPlain(cornerRadius: CGFloat) -> DSPlainButtonStyle {
        DSPlainButtonStyle(cornerRadius: cornerRadius)
    }
}
