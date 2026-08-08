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

    /// What the badge *draws*, which is not always what it announces.
    ///
    /// `DELETE` and `OPTIONS` are the only two methods wide enough to force every badge in the
    /// window to be wider than the rest need — so they compact, and the badge shrinks from 64pt to
    /// 44. Compaction is display-only: ``accessibilityLabel`` keeps the full method, because
    /// "DEL method" is not what a screen reader should say about a DELETE.
    static func displayToken(for method: String) -> String {
        switch method.uppercased() {
        case "DELETE": "DEL"
        case "OPTIONS": "OPT"
        default: method.uppercased()
        }
    }

    public init(method: String, size: DSMethodBadgeSize = .standard, identifier: String = "") {
        self.method = method.uppercased()
        self.size = size
        self.identifier = identifier.isEmpty ? method.lowercased() : identifier
    }

    public var body: some View {
        Text(Self.displayToken(for: method))
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
                    .fill(color.opacity(0.13))
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
    /// `codeBadge` — 9.5pt SF Mono semibold, the tier that exists for exactly this.
    ///
    /// It was `codeBold` (12pt) and `codeSmall` (11pt), which is what made 44pt impossible: `PATCH`
    /// measures **37.1pt** at 12pt SF Mono, so with 4pt of padding either side it needs 45.1 and
    /// overflows the frame — a `Text` with no line limit resolves that by wrapping and taking the
    /// row's height with it. At 9.5pt the same five characters are 29.4pt and the badge has room.
    ///
    /// Caught by a test rather than on screen, which is the point of measuring the advance rather
    /// than assuming 0.6em × size and rounding down.
    var font: Font {
        switch self {
        case .standard: DSTypography.codeBadge
        case .compact: DSTypography.codeBadge
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

    /// One width for every method, so paths start at the same x on every row — the whole reason a
    /// badge exists rather than a coloured word.
    ///
    /// **44, down from 64/56.** It was sized for `OPTIONS` at full length; with `DELETE` → `DEL` and
    /// `OPTIONS` → `OPT` the widest token is four characters, and 44pt holds `PATCH` (five at
    /// 0.6em/12pt = 36pt) with room either side. Twenty points back on every row of the navigator
    /// and the request log, which is where the path column needed them.
    var badgeWidth: CGFloat {
        switch self {
        case .compact: 44
        case .standard: 44
        }
    }

    /// Fixed, so a list of badges keeps its row rhythm whatever methods are in it. The standard size
    /// is the workspace's 20pt row-control height; the compact one is sized for a dense list.
    var height: CGFloat {
        switch self {
        case .compact: 15
        case .standard: 15
        }
    }
}
