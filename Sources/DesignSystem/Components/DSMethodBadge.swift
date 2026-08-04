import SwiftUI

/// Size variant for method badges.
public enum DSMethodBadgeSize {
    /// Standard size (12px code font) — editor, inspector, log rows
    case standard
    /// Compact size (11px) with tighter padding — sidebar rows
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

    public init(method: String, size: DSMethodBadgeSize = .standard, identifier: String = "") {
        self.method = method.uppercased()
        self.size = size
        self.identifier = identifier.isEmpty ? method.lowercased() : identifier
    }

    public var body: some View {
        Text(method)
            .font(size.font)
            // Both sizes, not just the large one. The compact badge was the *lighter* of the two at
            // `.medium` weight, which is backwards: 11pt of saturated colour on a 16% tint of itself
            // needs more weight to hold its edges, not less.
            .fontWeight(.semibold)
            // A method that somehow does not fit truncates; it does not grow the row.
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            // A fixed width, not a floor. `minWidth` let GET come out 54pt and OPTIONS 58pt, so a
            // column of badges still had a ragged edge — and 58pt is exactly the frame `SidebarView`
            // wraps them in, leaving the widest method zero slack against the clipping bug this
            // component was already fixed for once.
            .frame(width: size.badgeWidth, height: size.height)
            .background {
                RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                    .fill(color.opacity(0.16))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                    .stroke(color.opacity(0.30), lineWidth: 0.5)
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
        case .standard: DSTypography.codeBold
        case .compact: DSTypography.codeSmall
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        // Was `DSSpacing.xs + 2`, which is what pushed compact `OPTIONS` past the 58pt the sidebar
        // reserves for it. SF Mono's advance is 0.6em, so seven characters at 11pt is 46.2pt; 4pt
        // either side lands the widest method at 54.2pt, inside every frame a caller gives it.
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
        case .compact: 56
        case .standard: 64
        }
    }

    /// Fixed, so a list of badges keeps its row rhythm whatever methods are in it. The standard size
    /// is the workspace's 20pt row-control height; the compact one is sized for a dense list.
    var height: CGFloat {
        switch self {
        case .compact: 16
        case .standard: 20
        }
    }
}
