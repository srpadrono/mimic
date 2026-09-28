import SwiftUI

/// An inline message above the content it concerns, with at most one action.
public struct DSBanner: View {
    public enum Kind {
        case info
        case warning
        case error

        var systemImage: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "exclamationmark.octagon.fill"
            }
        }

        var ink: Color {
            switch self {
            case .info: DSColors.accent
            case .warning: DSColors.warning
            case .error: DSColors.error
            }
        }

        var fill: Color {
            switch self {
            case .info: DSColors.infoBackground
            case .warning: DSColors.warningBackground
            case .error: DSColors.errorBackground
            }
        }
    }

    private let kind: Kind
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?
    private let identifier: String

    public init(_ kind: Kind, message: String, actionTitle: String? = nil, identifier: String,
                action: (() -> Void)? = nil) {
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.identifier = identifier
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.systemImage)
                .font(.system(size: DSGlyph.button, weight: .regular))
                .foregroundStyle(kind.ink)
                .accessibilityHidden(true)
            Text(message)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("\(identifier).message")
            if let actionTitle, let action {
                DSButton(actionTitle, variant: .secondary, size: .small, identifier: "\(identifier).action",
                         action: action)
            }
        }
        .padding(.leading, DSSpacing.md)
        .padding(.trailing, 10)
        .padding(.vertical, DSSpacing.sm)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.card).fill(kind.fill)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
