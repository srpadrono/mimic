import SwiftUI

/// Explicit outer geometry, shared by toolbar buttons, menus, and status wells.
/// Native toolbar backgrounds must be hidden for items using this surface.
public struct DSToolbarPill: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    public init() {}

    public func body(content: Content) -> some View {
        content
            .font(DSTypography.bodyMedium)
            .lineLimit(1)
            .frame(minWidth: DSToolbarGeometry.contentHeight)
            .frame(height: DSToolbarGeometry.contentHeight)
            .padding(.horizontal, DSToolbarGeometry.horizontalInset)
            .frame(height: DSToolbarGeometry.height)
            .background {
                Capsule()
                    .fill(isHovered && isEnabled ? DSColors.accentSubtle : DSColors.tertiary)
                    .strokeBorder(DSColors.border, lineWidth: DSStroke.hairline)
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: DSAnimation.micro), value: isHovered)
    }
}

/// Insets belong to the label, so the entire pill—not just its glyph—is clickable.
public struct DSToolbarButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(DSToolbarPill())
            .overlay {
                Capsule()
                    .fill(configuration.isPressed ? DSColors.accentMuted : .clear)
                    .allowsHitTesting(false)
            }
    }
}
