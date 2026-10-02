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
///
/// Sized by its text, as the EmptyStates artboard draws it: a 220pt column inside 18pt of padding,
/// so 256pt across, and as tall as its content. Cards sharing a row line up by being placed with
/// `fillsHeight`, which stretches the card to whatever height its row gives it.
public struct DSOptionCard: View {
    private let systemImage: String?
    private let title: String
    private let message: String
    private let footnote: String?
    private let shortcut: [String]
    private let isDefault: Bool
    private let fillsHeight: Bool
    private let identifier: String
    private let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    /// The card's width at rest: a 220pt text column and its padding.
    public static let width: CGFloat = textWidth + 2 * padding
    /// The narrowest a card gets before a row of them wraps: a 168pt text column and its padding.
    public static let minimumWidth: CGFloat = 168 + 2 * padding

    private static let textWidth: CGFloat = 220
    private static let padding: CGFloat = 18
    /// The ring the default card wears outside its border, as the board's 3px focus-style shadow.
    private static let defaultRing: CGFloat = 3
    /// The symbol's point size. The board draws 22pt icon boxes whose strokes fill about 16pt of
    /// them; SF Symbols at 17pt cover the same ground inside the same `DSGlyph.card` box.
    private static let symbolSize: CGFloat = 17

    public init(_ title: String, systemImage: String? = nil, message: String, footnote: String? = nil,
                shortcut: [String] = [], isDefault: Bool = false, fillsHeight: Bool = false,
                identifier: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.footnote = footnote
        self.shortcut = shortcut
        self.isDefault = isDefault
        self.fillsHeight = fillsHeight
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                if let systemImage {
                    // The default choice's symbol is in the accent, the others in secondary ink.
                    Image(systemName: systemImage)
                        .font(.system(size: Self.symbolSize, weight: .regular))
                        .foregroundStyle(isDefault ? DSColors.accent : DSColors.labelSecondary)
                        .frame(width: DSGlyph.card, height: DSGlyph.card)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(DSTypography.bodySemibold)
                    .foregroundStyle(DSColors.labelPrimary)
                Text(message)
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineSpacing(DSTypography.Leading.tight)
                    .fixedSize(horizontal: false, vertical: true)
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
            .padding(Self.padding)
            .frame(minWidth: Self.minimumWidth, idealWidth: Self.width, maxWidth: Self.width,
                   maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: DSCornerRadius.panel, style: .continuous)
                    .fill(isHovered ? DSColors.hover : DSColors.zebra)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DSCornerRadius.panel, style: .continuous)
                    .strokeBorder(isDefault ? DSColors.accent : DSColors.separator,
                                  lineWidth: isDefault ? DSStroke.emphasis : DSStroke.hairline)
            }
            // A ring outside the border only. Filling behind the card instead tints the whole
            // card, because the card's own fill is translucent.
            .background {
                if isDefault {
                    RoundedRectangle(cornerRadius: DSCornerRadius.panel + Self.defaultRing, style: .continuous)
                        .strokeBorder(DSColors.selectionSoft, lineWidth: Self.defaultRing)
                        .padding(-Self.defaultRing)
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
