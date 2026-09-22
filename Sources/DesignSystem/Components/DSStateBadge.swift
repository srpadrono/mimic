import SwiftUI

public enum DSStateTone {
    case accent
    case warning

    var textColor: Color {
        switch self {
        case .accent: DSColors.accentText
        case .warning: DSColors.warningText
        }
    }
}

/// A short named state on a subtle semantic tint. The word carries the meaning; color helps locate it.
public struct DSStateBadge: View {
    // A lighter fill preserves AA contrast for accent text on the editor header in light mode.
    public static let fillOpacity: Double = 0.10

    private let title: String
    private let tone: DSStateTone
    private let systemImage: String?
    private let identifier: String

    public init(_ title: String, tone: DSStateTone, systemImage: String? = nil, identifier: String) {
        self.title = title
        self.tone = tone
        self.systemImage = systemImage
        self.identifier = identifier
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .font(DSTypography.labelMedium)
        .foregroundStyle(tone.textColor)
        .lineLimit(1)
        .padding(.horizontal, DSSpacing.xs)
        .padding(.vertical, 1)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.xs)
                .fill(tone.textColor.opacity(Self.fillOpacity))
        }
        .fixedSize()
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }
}
