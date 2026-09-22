import SwiftUI

/// Shared surface for compact fields that already have a label beside them. Full form fields use
/// `DSTextField`; this gives inline editor fields the same inset, height, radius and border.
public struct DSFieldWell: ViewModifier {
    private let width: CGFloat?
    private let maxWidth: CGFloat?
    private let isInvalid: Bool
    @FocusState private var isFocused: Bool

    public init(width: CGFloat? = nil, maxWidth: CGFloat? = nil, isInvalid: Bool = false) {
        self.width = width
        self.maxWidth = maxWidth
        self.isInvalid = isInvalid
    }

    public func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .dsControlWell(
                height: DSControlHeight.field,
                fill: DSColors.tertiary,
                stroke: isInvalid ? DSColors.destructive : isFocused ? DSColors.borderFocused : DSColors.border,
                strokeWidth: isFocused ? DSStroke.focusRing : DSStroke.hairline,
                width: width,
                maxWidth: maxWidth
            )
            .animation(.easeOut(duration: DSAnimation.fast), value: isFocused)
    }
}

public extension View {
    func dsFieldWell(width: CGFloat? = nil, maxWidth: CGFloat? = nil, isInvalid: Bool = false) -> some View {
        modifier(DSFieldWell(width: width, maxWidth: maxWidth, isInvalid: isInvalid))
    }
}
