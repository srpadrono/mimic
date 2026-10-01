import SwiftUI

/// The journey glyph the design draws: two points joined by a path that doubles back on itself.
///
/// The nearest SF Symbol, `point.topleft.down.to.point.bottomright.curvepath`, runs its path on a
/// diagonal; the design's runs level, turns, and runs level again, like the steps of a journey. Drawn
/// on the design's 16-unit grid with its 1.5-unit stroke, so it scales with `size`.
public struct DSJourneyGlyph: View {
    private let size: CGFloat

    public init(size: CGFloat = DSGlyph.control) {
        self.size = size
    }

    public var body: some View {
        JourneyGlyphShape()
            .stroke(style: StrokeStyle(lineWidth: 1.5 * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private nonisolated struct JourneyGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        var path = Path()
        path.addEllipse(in: CGRect(origin: point(2.25, 2.25), size: CGSize(width: 3.5 * unit, height: 3.5 * unit)))
        path.addEllipse(in: CGRect(origin: point(10.25, 10.25), size: CGSize(width: 3.5 * unit, height: 3.5 * unit)))
        // M5.75 4 H10 a2 2 0 0 1 0 4 H6 a2 2 0 0 0 0 4 h4.25
        path.move(to: point(5.75, 4))
        path.addLine(to: point(10, 4))
        path.addArc(center: point(10, 6), radius: 2 * unit,
                    startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: point(6, 8))
        path.addArc(center: point(6, 10), radius: 2 * unit,
                    startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: point(10.25, 12))
        return path
    }
}
