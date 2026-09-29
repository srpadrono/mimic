import SwiftUI

/// The live radio: a green ring with a dot when a scenario is served, an empty ring when it is not.
public struct DSLiveIndicator: View {
    private let isLive: Bool
    private let size: CGFloat

    @Environment(\.backgroundProminence) private var prominence

    public init(isLive: Bool, size: CGFloat = 14) {
        self.isLive = isLive
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(ring, lineWidth: size >= 12 ? 1.5 : 1)
            if isLive {
                Circle()
                    .fill(ring)
                    .frame(width: size * 3 / 7, height: size * 3 / 7)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var ring: Color {
        if prominence == .increased { return .white }
        return isLive ? DSColors.success : DSColors.labelTertiary
    }
}

/// A large choice on an empty screen: title, one line of explanation, and a hint underneath.
public struct DSOptionCard: View {
    private let systemImage: String?
    private let title: String
    private let message: String
    private let footnote: String?
    private let shortcut: [String]
    private let isDefault: Bool
    private let identifier: String
    private let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, systemImage: String? = nil, message: String, footnote: String? = nil,
                shortcut: [String] = [], isDefault: Bool = false, identifier: String,
                action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.footnote = footnote
        self.shortcut = shortcut
        self.isDefault = isDefault
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                if let systemImage {
                    // The default choice's symbol is in the accent, the others in secondary ink.
                    Image(systemName: systemImage)
                        .font(.system(size: DSGlyph.card, weight: .regular))
                        .foregroundStyle(isDefault ? DSColors.accent : DSColors.labelSecondary)
                        .frame(height: DSGlyph.card)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(DSTypography.bodySemibold)
                    .foregroundStyle(DSColors.labelPrimary)
                Text(message)
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineSpacing(DSTypography.Leading.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !shortcut.isEmpty {
                    HStack(spacing: DSSpacing.xs) {
                        ForEach(shortcut, id: \.self) { key in
                            Text(key)
                                .font(DSTypography.caption.weight(.medium))
                                .foregroundStyle(DSColors.labelTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay {
                                    RoundedRectangle(cornerRadius: DSCornerRadius.mark)
                                        .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
                                }
                        }
                    }
                    .accessibilityHidden(true)
                } else if let footnote {
                    Text(footnote)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.labelTertiary)
                }
            }
            .padding(18)
            // 220pt as designed, narrowing to 168pt so three still share a row in a narrow pane.
            .frame(minWidth: 168, idealWidth: 220, maxWidth: 220, alignment: .topLeading)
            .frame(minHeight: systemImage == nil ? 132 : 164, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: DSCornerRadius.panel, style: .continuous)
                    .fill(isHovered ? DSColors.hover : DSColors.zebra)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DSCornerRadius.panel, style: .continuous)
                    .strokeBorder(isDefault ? DSColors.accent : DSColors.separator,
                                  lineWidth: isDefault ? DSStroke.emphasis : DSStroke.hairline)
            }
            .background {
                if isDefault {
                    RoundedRectangle(cornerRadius: DSCornerRadius.panel + 3, style: .continuous)
                        .fill(DSColors.selectionSoft)
                        .padding(-3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DSCornerRadius.panel, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = isEnabled && $0 }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityHint(message)
    }
}
