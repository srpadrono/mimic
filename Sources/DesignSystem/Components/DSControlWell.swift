import SwiftUI

/// A rectangular field or filter surface. Callers supply semantic state colors while this component
/// owns the hit-area height, inset, radius and border treatment shared across workspace controls.
public struct DSControlWell: ViewModifier {
    private let height: CGFloat
    private let fill: Color
    private let stroke: Color
    private let strokeWidth: CGFloat
    private let width: CGFloat?
    private let minWidth: CGFloat?
    private let idealWidth: CGFloat?
    private let maxWidth: CGFloat?

    public init(
        height: CGFloat,
        fill: Color,
        stroke: Color,
        strokeWidth: CGFloat = DSStroke.hairline,
        width: CGFloat? = nil,
        minWidth: CGFloat? = nil,
        idealWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil
    ) {
        self.height = height
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.width = width
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
    }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, DSControlHeight.verticalPadding)
            .frame(width: width)
            .frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: DSCornerRadius.sm).fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                    .stroke(stroke, lineWidth: strokeWidth)
            }
    }
}

public extension View {
    func dsControlWell(
        height: CGFloat,
        fill: Color,
        stroke: Color,
        strokeWidth: CGFloat = DSStroke.hairline,
        width: CGFloat? = nil,
        minWidth: CGFloat? = nil,
        idealWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil
    ) -> some View {
        modifier(DSControlWell(height: height, fill: fill, stroke: stroke,
                               strokeWidth: strokeWidth, width: width, minWidth: minWidth,
                               idealWidth: idealWidth, maxWidth: maxWidth))
    }
}
