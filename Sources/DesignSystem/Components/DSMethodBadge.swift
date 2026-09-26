import SwiftUI

/// Size variant for method badges.
public enum DSMethodBadgeSize {
    /// Standard size (12.5pt code font) — editor and inspector.
    case standard
    /// Compact size (11.5pt) with tighter padding — sidebar and table rows.
    case compact
}

/// HTTP method chip with bold color presence.
///
/// **Uppercase on purpose.** `GET` and `DELETE` are protocol tokens, not shouted prose, so the
/// design system's sentence-case rule does not apply — and the casing is applied once in `init`
/// rather than with `.textCase`, so what a caller passes is what a test can assert on.
///
/// **The width is stable across methods**, which is the whole reason a badge exists rather than a
/// coloured word. Sized to its content, `GET` came out around 32pt and `DELETE` around 52pt, so a
/// column of them in the sidebar or the request log had a ragged right edge and the paths beside
/// them started at a different place on every row. Worse, compact `OPTIONS` wanted 58.2pt inside
/// the 58pt frame the sidebar and the journey step row give it — 0.2pt over, which a `Text` with no
/// line limit resolves by wrapping onto a second line and taking the row's height with it. Every
/// badge is now as wide as the longest method it could ever hold.
public struct DSMethodBadge: View {
    private let method: String
    private let size: DSMethodBadgeSize
    private let identifier: String

    /// - Parameter identifier: required, and deliberately has no default.
    ///
    ///   It used to fall back to the method name, which reads as a sensible default and is not one:
    ///   every GET row in the request log then emitted `ds.method.get`, so a hundred-row traffic list
    ///   published a hundred elements sharing one identifier and `app.otherElements["ds.method.get"]`
    ///   resolved to whichever AppKit happened to hand back first. An identifier that is not unique
    ///   is worse than none, because a query written against it appears to work.
    public init(method: String, size: DSMethodBadgeSize = .standard, identifier: String) {
        self.method = method.uppercased()
        self.size = size
        self.identifier = identifier
    }

    public var body: some View {
        Text(method)
            .font(size.font)
            // A method that somehow does not fit truncates; it does not grow the row.
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            // A fixed width, not a floor. `minWidth` let GET come out 54pt and OPTIONS 58pt, so a
            // column of badges still had a ragged edge. The width now fits the largest method at the
            // readable badge font without forcing the adjacent path to move between rows.
            .frame(width: size.badgeWidth, height: size.height)
            .background {
                RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                    .fill(color.opacity(0.16))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                    .stroke(color.opacity(0.30), lineWidth: DSStroke.hairline)
            }
            .accessibilityIdentifier("ds.method.\(identifier)")
            .accessibilityLabel("\(method) method")
    }

    private var color: Color {
        DSColors.methodColor(for: method)
    }
}

// MARK: - Geometry

private extension DSMethodBadgeSize {
    var font: Font {
        switch self {
        case .standard: DSTypography.codeBadgeStandard
        case .compact: DSTypography.codeBadgeCompact
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        // Was `DSSpacing.xs + 2`, which is what pushed compact `OPTIONS` past the 58pt the sidebar
        // reserves for it. SF Mono's advance is about 0.6em, so seven characters at 11.5pt take
        // about 48.3pt; 4pt on either side lands the widest method at about 56.3pt,
        // inside the 58pt compact frame.
        case .compact: DSSpacing.xs
        case .standard: DSSpacing.sm
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: 1
        case .standard: 2
        }
    }

    /// One width for every method, with a little slack over the measured widest token so a font
    /// substitution cannot push it back over the edge.
    var badgeWidth: CGFloat {
        switch self {
        case .compact: 58
        case .standard: 66
        }
    }

    /// Fixed, so a list of badges keeps its row rhythm whatever methods are in it.
    var height: CGFloat {
        switch self {
        case .compact: 18
        case .standard: 22
        }
    }
}
