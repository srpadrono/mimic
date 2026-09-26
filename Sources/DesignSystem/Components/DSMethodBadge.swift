import SwiftUI

/// Size variant for method badges.
public enum DSMethodBadgeSize {
    /// Standard size (12.5pt) for the editor and inspector.
    case standard
    /// Compact size (11.5pt) for sidebar and table rows.
    case compact
}

/// An uppercase HTTP method label with stable width across supported methods.
public struct DSMethodBadge: View {
    private let method: String
    private let size: DSMethodBadgeSize
    private let identifier: String

    /// Provide a row-specific identifier so repeated methods remain independently accessible.
    public init(method: String, size: DSMethodBadgeSize = .standard, identifier: String) {
        self.method = method.uppercased()
        self.size = size
        self.identifier = identifier
    }

    public var body: some View {
        Text(method)
            .font(size.font)
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
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

private extension DSMethodBadgeSize {
    var font: Font {
        switch self {
        case .standard: DSTypography.codeBadgeStandard
        case .compact: DSTypography.codeBadgeCompact
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
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

    /// Fits OPTIONS in SF Mono without shifting adjacent paths.
    var badgeWidth: CGFloat {
        switch self {
        case .compact: 58
        case .standard: 66
        }
    }

    /// A fixed height preserves row rhythm across methods.
    var height: CGFloat {
        switch self {
        case .compact: 18
        case .standard: 22
        }
    }
}
