import SwiftUI

// Legacy well used by panes that have not moved to `dsFieldChrome`. Delete with DSLegacyTokens.swift.
public struct DSControlWell: ViewModifier {
    private let height: CGFloat
    private let width: CGFloat?
    private let minWidth: CGFloat?
    private let idealWidth: CGFloat?
    private let maxWidth: CGFloat?

    public init(height: CGFloat, fill: Color, stroke: Color, strokeWidth: CGFloat = DSStroke.hairline,
                width: CGFloat? = nil, minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil,
                maxWidth: CGFloat? = nil) {
        self.height = height
        self.width = width
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
    }

    public func body(content: Content) -> some View {
        content
            .dsFieldChrome(height: height, isFocused: false)
            .frame(width: width)
            .frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth)
    }
}

public extension View {
    func dsControlWell(height: CGFloat, fill: Color, stroke: Color, strokeWidth: CGFloat = DSStroke.hairline,
                       width: CGFloat? = nil, minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil,
                       maxWidth: CGFloat? = nil) -> some View {
        modifier(DSControlWell(height: height, fill: fill, stroke: stroke, strokeWidth: strokeWidth,
                               width: width, minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth))
    }
}
