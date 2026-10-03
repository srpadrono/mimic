import SwiftUI

/// The dropped-connection glyph the design draws: a line cut through by a slash.
///
/// No SF Symbol draws a broken line; `bolt.horizontal`, the nearest, reads as a zig-zag and is wider.
/// Drawn on the design's 16-unit grid with its 1.5-unit stroke, so it scales with `size`.
public struct DSConnectionDropGlyph: View {
    private let size: CGFloat

    public init(size: CGFloat = DSGlyph.paneAction) {
        self.size = size
    }

    public var body: some View {
        ConnectionDropShape()
            .stroke(style: StrokeStyle(lineWidth: 1.5 * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private nonisolated struct ConnectionDropShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        // M2 8h4 M10 8h4 M6 5l4 6
        var path = Path()
        path.move(to: point(2, 8))
        path.addLine(to: point(6, 8))
        path.move(to: point(10, 8))
        path.addLine(to: point(14, 8))
        path.move(to: point(6, 5))
        path.addLine(to: point(10, 11))
        return path
    }
}
