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

/// Capsule heights: 28pt in sheets, 24pt in panels, 20pt inside a row or banner.
public enum DSButtonSize: CaseIterable {
    case small
    case medium
    case large

    public var height: CGFloat {
        switch self {
        case .small: DSControlHeight.small
        case .medium: DSControlHeight.regular
        case .large: DSControlHeight.large
        }
    }

    var font: Font {
        switch self {
        case .small: DSTypography.caption.weight(.medium)
        case .medium, .large: DSTypography.bodyMedium
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: 9
        case .medium: DSSpacing.md
        case .large: DSSpacing.lg
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
            DSButtonLabel(title: title, systemImage: systemImage, showsTitle: showsTitle)
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

    public init(title: String, systemImage: String? = nil, showsTitle: Bool = true) {
        self.title = title
        self.systemImage = systemImage
        self.showsTitle = showsTitle || systemImage == nil
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xs + 1) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: DSGlyph.button - 1, weight: .medium))
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
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(size.font)
                .foregroundStyle(ink)
                .padding(.horizontal, variant == .ghost ? DSSpacing.sm : size.horizontalPadding)
                .frame(height: size.height)
                .background {
                    Capsule().fill(fill)
                }
                .overlay {
                    if variant == .secondary {
                        Capsule().strokeBorder(DSColors.fieldBorder, lineWidth: DSStroke.hairline)
                    }
                }
                .overlay {
                    Capsule().fill(shade)
                }
                .contentShape(Capsule())
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
            case .secondary: DSColors.field
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
    private let action: () -> Void

    public init(_ label: String, systemImage: String, identifier: String, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: DSGlyph.control, weight: .regular))
                .frame(width: DSControlHeight.regular, height: DSControlHeight.regular)
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
