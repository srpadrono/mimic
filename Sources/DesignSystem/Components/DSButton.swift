import SwiftUI

/// What a button does, which decides how loud it is. One primary per view.
///
/// `nonisolated` so tests can sweep every variant without hopping to the main actor.
public nonisolated enum DSButtonVariant: CaseIterable {
    /// Accent capsule with white text: the action the view exists for.
    case primary
    /// Field-filled capsule with a hairline: every other action.
    case secondary
    /// Red text, no fill: removes something. Confirmations use a native alert.
    case destructive
    /// Secondary text, no fill: a tool beside content, like Format or Copy.
    case ghost
}

/// Capsule heights: 28pt in sheets, 24pt in panels, 22pt beside a value in a settings row, 20pt
/// inside a row or banner.
public enum DSButtonSize: CaseIterable {
    case small
    /// Beside a value inside a grouped settings row, such as Copy after a URL.
    case inline
    case medium
    case large
    /// The boards' bare link button beside content: 12pt regular in a 24pt slot, 6pt either side,
    /// a 12pt glyph, and a rounded-square hover wash rather than a capsule. With `.ghost` it is the
    /// editor's Format and Copy.
    case compact

    public var height: CGFloat {
        switch self {
        case .small: DSControlHeight.small
        case .inline: DSControlHeight.inline
        case .medium, .compact: DSControlHeight.regular
        case .large: DSControlHeight.large
        }
    }

    var font: Font {
        switch self {
        case .small: DSTypography.caption.weight(.medium)
        case .inline: DSTypography.calloutMedium
        case .medium, .large: DSTypography.bodyMedium
        case .compact: DSTypography.callout
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: 9
        case .inline: 10
        case .medium: DSSpacing.md
        case .large: DSSpacing.lg
        case .compact: 6
        }
    }

    /// The symbol beside the title.
    var glyphFont: Font {
        switch self {
        case .compact: .system(size: DSGlyph.field, weight: .regular)
        case .small, .inline, .medium, .large: .system(size: DSGlyph.button - 1, weight: .medium)
        }
    }
}

/// A capsule button with an optional leading symbol.
public struct DSButton: View {
    private let title: String
    private let systemImage: String?
    private let variant: DSButtonVariant
    private let size: DSButtonSize
    private let showsTitle: Bool
    private let action: () -> Void
    private let identifier: String

    /// `showsTitle: false` draws the symbol alone, for a narrow bar; the title stays the button's
    /// accessibility label, so give such a button a `.help` tooltip as well.
    public init(
        _ title: String,
        systemImage: String? = nil,
        variant: DSButtonVariant = .primary,
        size: DSButtonSize = .medium,
        showsTitle: Bool = true,
        identifier: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.variant = variant
        self.size = size
        self.showsTitle = showsTitle || systemImage == nil
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        Button(role: variant == .destructive ? .destructive : nil, action: action) {
            DSButtonLabel(title: title, systemImage: systemImage, showsTitle: showsTitle, size: size)
        }
        .buttonStyle(DSButtonStyle(variant, size: size))
        .accessibilityIdentifier("ds.button.\(identifier)")
        .accessibilityLabel(title)
    }
}

/// A title with an optional symbol at the button glyph size.
public struct DSButtonLabel: View {
    let title: String
    let systemImage: String?
    let showsTitle: Bool
    let size: DSButtonSize

    /// `size` sets the symbol's size and weight; pass the size of the style the label is drawn in.
    public init(title: String, systemImage: String? = nil, showsTitle: Bool = true, size: DSButtonSize = .medium) {
        self.title = title
        self.systemImage = systemImage
        self.showsTitle = showsTitle || systemImage == nil
        self.size = size
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xs + 1) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(size.glyphFont)
                    .accessibilityHidden(true)
            }
            if showsTitle {
                Text(title)
                    .lineLimit(1)
            }
        }
    }
}

/// The capsule button style, usable on any `Button` or `Menu`.
public struct DSButtonStyle: ButtonStyle {
    let variant: DSButtonVariant
    let size: DSButtonSize

    public init(_ variant: DSButtonVariant = .secondary, size: DSButtonSize = .medium) {
        self.variant = variant
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        Surface(variant: variant, size: size, configuration: configuration)
    }

    private struct Surface: View {
        let variant: DSButtonVariant
        let size: DSButtonSize
        let configuration: ButtonStyleConfiguration

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.dsSurface) private var surface
        @State private var isHovered = false

        var body: some View {
            if size == .compact {
                styled(RoundedRectangle(cornerRadius: DSCornerRadius.field, style: .continuous))
            } else {
                styled(Capsule())
            }
        }

        private var horizontalPadding: CGFloat {
            // A ghost button is a tool beside content, so it sits closer to it than a capsule does.
            // The compact size states its own, the boards' link-button padding.
            variant == .ghost && size != .compact ? DSSpacing.sm : size.horizontalPadding
        }

        private func styled<Outline: InsettableShape>(_ outline: Outline) -> some View {
            configuration.label
                .font(size.font)
                .foregroundStyle(ink)
                .padding(.horizontal, horizontalPadding)
                .frame(height: size.height)
                .background {
                    outline.fill(fill)
                }
                .overlay {
                    if variant == .secondary {
                        outline.strokeBorder(surface.fieldBorder, lineWidth: DSStroke.hairline)
                    }
                }
                .overlay {
                    outline.fill(shade)
                }
                .contentShape(outline)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.easeOut(duration: DSAnimation.fast), value: configuration.isPressed)
                .animation(.easeOut(duration: DSAnimation.fast), value: isHovered)
                .onHover { isHovered = isEnabled && $0 }
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled { isHovered = false }
                }
        }

        private var ink: Color {
            switch variant {
            case .primary: .white
            case .secondary: DSColors.labelPrimary
            case .destructive: DSColors.error
            case .ghost: isHovered ? DSColors.labelPrimary : DSColors.labelSecondary
            }
        }

        private var fill: Color {
            switch variant {
            case .primary: DSColors.accent
            case .secondary: surface.fieldFill
            case .destructive, .ghost: isHovered ? DSColors.hover : .clear
            }
        }

        private var shade: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return .black.opacity(0.12) }
            if isHovered, variant == .primary || variant == .secondary { return .black.opacity(0.05) }
            return .clear
        }
    }
}

public extension ButtonStyle where Self == DSButtonStyle {
    static func ds(_ variant: DSButtonVariant, size: DSButtonSize = .medium) -> DSButtonStyle {
        DSButtonStyle(variant, size: size)
    }
}

/// An icon-only button for a panel header or row: add, clear, more.
public struct DSIconButton: View {
    private let systemImage: String
    private let label: String
    private let identifier: String
    private let glyphSize: CGFloat
    private let weight: Font.Weight
    private let width: CGFloat
    private let action: () -> Void

    /// `glyphSize`, `weight` and `width` default to a panel header's icon button; the request log's
    /// clear button passes the smaller, heavier glyph and wider hit area its board draws.
    public init(_ label: String, systemImage: String, identifier: String,
                glyphSize: CGFloat = DSGlyph.control, weight: Font.Weight = .regular,
                width: CGFloat = DSControlHeight.regular, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.identifier = identifier
        self.glyphSize = glyphSize
        self.weight = weight
        self.width = width
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: weight))
                .frame(width: width, height: DSControlHeight.regular)
        }
        .buttonStyle(DSIconButtonStyle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// Secondary glyph, hover wash in a rounded square.
public struct DSIconButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.dsSurface) private var surface
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered ? DSColors.labelPrimary : DSColors.labelSecondary)
                .background {
                    RoundedRectangle(cornerRadius: DSCornerRadius.field)
                        .fill(configuration.isPressed ? DSColors.selectionInactive : isHovered ? DSColors.hover : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: DSCornerRadius.field))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = isEnabled && $0 }
        }
    }
}
