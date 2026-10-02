import SwiftUI

/// The boards' thin chevron: a jump-bar separator, a pop-up's mark, a menu field's indicator.
///
/// Drawn from the boards' own 16-unit paths at their 1.5-unit stroke, scaled to a 10pt square, so
/// it is the hairline the design draws rather than an SF Symbol at a weight. Purely decorative: the
/// control it sits in carries the name.
public struct DSDisclosureChevron: View {
    /// Which way the chevron points.
    public nonisolated enum Direction: Sendable {
        /// `M6 3l5 5-5 5`: between two crumbs of a path.
        case right
        /// `M4 6l4 4 4-4`: a menu of shortcuts, a disclosure that is open.
        case down
        /// `M5 6l3-3 3 3M5 10l3 3 3-3`: a choice among peers, as a pop-up button marks it.
        case upDown
    }

    private let direction: Direction
    private let size: CGFloat
    private let color: Color

    /// `size` is the square the 16-unit path is scaled into; the stroke scales with it.
    public init(_ direction: Direction, size: CGFloat = DSGlyph.disclosure, color: Color = DSColors.labelTertiary) {
        self.direction = direction
        self.size = size
        self.color = color
    }

    public var body: some View {
        DSDisclosureChevronShape(direction: direction)
            .stroke(color, style: StrokeStyle(lineWidth: Self.strokeWidth(for: size), lineCap: .round,
                                              lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// The boards' 1.5-unit stroke at `size`: 0.94pt in the 10pt square.
    public nonisolated static func strokeWidth(for size: CGFloat) -> CGFloat {
        1.5 * size / 16
    }
}

/// The chevron's path in a square, from the boards' 16-unit coordinates.
public nonisolated struct DSDisclosureChevronShape: Shape {
    public let direction: DSDisclosureChevron.Direction

    public init(direction: DSDisclosureChevron.Direction) {
        self.direction = direction
    }

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 16
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()
        for stroke in Self.strokes(for: direction) {
            guard let first = stroke.first else { continue }
            path.move(to: point(first.x, first.y))
            for next in stroke.dropFirst() {
                path.addLine(to: point(next.x, next.y))
            }
        }
        return path
    }

    /// Each open polyline of the boards' path, in 16-unit coordinates.
    static func strokes(for direction: DSDisclosureChevron.Direction) -> [[CGPoint]] {
        switch direction {
        case .right:
            [[CGPoint(x: 6, y: 3), CGPoint(x: 11, y: 8), CGPoint(x: 6, y: 13)]]
        case .down:
            [[CGPoint(x: 4, y: 6), CGPoint(x: 8, y: 10), CGPoint(x: 12, y: 6)]]
        case .upDown:
            [[CGPoint(x: 5, y: 6), CGPoint(x: 8, y: 3), CGPoint(x: 11, y: 6)],
             [CGPoint(x: 5, y: 10), CGPoint(x: 8, y: 13), CGPoint(x: 11, y: 10)]]
        }
    }
}
