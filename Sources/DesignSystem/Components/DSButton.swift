import SwiftUI

/// Button style variant
public enum DSButtonVariant {
    case primary
    case secondary
    case destructive
    case ghost
}

/// Button size
public enum DSButtonSize {
    case small
    case medium
    case large
}

/// Reusable button with primary/secondary/destructive/ghost variants.
///
/// The four variants have to be tellable apart at rest, not only when you hover them, and not only
/// by hue. They used to differ by tint alone on the same shape — and worse, two of them collided:
/// `secondary` filled with `DSColors.secondary`, which *is* the sidebar/inspector/sheet surface, so
/// it rendered as bare text on every panel it was placed on, while `ghost` — the variant whose whole
/// promise is "no chrome" — was the one wearing a border. So each variant now differs in
/// construction:
///
/// - **primary** — a solid accent slab, no border. The one thing the sheet wants you to press.
/// - **secondary** — a recessed well with a hairline. Visible on any surface, because it does not
///   borrow the surface's own colour.
/// - **destructive** — a solid destructive slab *with a warning glyph*. A red fill is a hue, and a
///   hue is exactly what Differentiate Without Color, a projector, or a greyscale screenshot takes
///   away; the glyph is the part that survives. Same reasoning as `DSTextField`'s error row.
/// - **ghost** — accent text, no fill, no border. A link, essentially.
///
/// Sizes are the workspace's row geometry, not a scale someone invented: `.small` is the 20pt /
/// `DSCornerRadius.sm` / 0.5pt-hairline / 3pt-padding shape that every control in a panel header
/// wears, so a small button dropped into one of those rows lines up instead of standing a point
/// proud of its neighbours.
public struct DSButton: View {
    private let title: String
    private let variant: DSButtonVariant
    private let size: DSButtonSize
    private let action: () -> Void
    private let identifier: String

    public init(
        _ title: String,
        variant: DSButtonVariant = .primary,
        size: DSButtonSize = .medium,
        identifier: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.variant = variant
        self.size = size
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        Button(role: variant == .destructive ? .destructive : nil, action: action) {
            HStack(spacing: DSSpacing.xs) {
                if variant == .destructive {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: size.glyphSize, weight: .semibold))
                        // The title already says what will be destroyed; the glyph is a visual
                        // marker, and VoiceOver reads the explicit label below.
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(size.font)
                    // One line, always. A button that grows a second line inside a header row takes
                    // the row's height with it.
                    .lineLimit(1)
            }
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(height: size.height)
        }
        .buttonStyle(DSButtonStyle(variant: variant, cornerRadius: size.cornerRadius))
        .accessibilityIdentifier("ds.button.\(identifier)")
        .accessibilityLabel(title)
    }
}

// MARK: - Geometry

/// A hairline, not a border. At 1pt a row of buttons reads as a form.
private let dsButtonBorderWidth = DSStroke.hairline

private extension DSButtonSize {
    /// Fixed, so two buttons of the same size are the same height whatever their titles.
    ///
    /// `.small` is 20pt because that is the workspace's row-control height. `.medium` is 22pt, which
    /// is both a 13pt line plus 3pt above and below *and* the height AppKit gives a regular push
    /// button — so a `.medium` button standing next to a system `Picker` in a sheet lines up.
    var height: CGFloat {
        switch self {
        case .small: DSControlHeight.row
        case .medium: DSControlHeight.field
        case .large: DSControlHeight.prominent
        }
    }

    var font: Font {
        switch self {
        case .small: DSTypography.label
        case .medium: DSTypography.body
        case .large: DSTypography.bodyBold
        }
    }

    /// Never below 8pt, and a step *under* the line it sits beside rather than level with it.
    ///
    /// The rungs are `DSGlyph`'s: `.small` sets `DSTypography.label` (11) and takes the inline rung at
    /// 10, while `.medium` and `.large` both set 13pt lines and take control rungs at 11 and 12.
    ///
    /// This used to promise the glyph was "never smaller than the text it sits beside", which no
    /// size here has ever satisfied — and should not. An SF Symbol drawn at a line's own point size
    /// reads *larger* than the line, because the glyph fills the em box where a letter leaves room
    /// above and below it. Matching the numbers is what makes the warning triangle look oversized,
    /// not what makes it match.
    var glyphSize: CGFloat {
        switch self {
        case .small: DSGlyph.inline
        case .medium: DSGlyph.control
        case .large: DSGlyph.controlLarge
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: DSSpacing.sm
        case .medium: DSSpacing.md
        case .large: DSSpacing.lg
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .small, .medium: DSControlHeight.verticalPadding
        case .large: DSSpacing.sm
        }
    }

    /// `sm` for the row sizes so a small button matches the wells it sits between; `md` for the
    /// sheet sizes, where a 4pt radius on a 28pt slab reads as a chip rather than a button.
    var cornerRadius: CGFloat {
        switch self {
        case .small: DSCornerRadius.sm
        case .medium, .large: DSCornerRadius.md
        }
    }
}

// MARK: - Style

private struct DSButtonStyle: ButtonStyle {
    let variant: DSButtonVariant
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Surface(variant: variant, cornerRadius: cornerRadius, configuration: configuration)
    }

    /// The style's chrome, as an actual `View`.
    ///
    /// The hover flag used to be `@State` on the `ButtonStyle` itself. A `ButtonStyle` is not a
    /// `View`, so SwiftUI never installs storage for it: the flag read `false` forever, and the
    /// ghost variant — whose only resting appearance *is* its hover fill — therefore had no hover
    /// feedback at all, while `.onHover` wrote into unattached state. Hover state belongs to a view,
    /// so here is the view.
    private struct Surface: View {
        let variant: DSButtonVariant
        let cornerRadius: CGFloat
        let configuration: ButtonStyleConfiguration

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(background)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(border, lineWidth: dsButtonBorderWidth)
                }
                // Ghost has no fill at rest, and an unfilled shape is not hit-testable — without
                // this the target was the glyphs of the word and the gaps between them were not.
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                // A custom `ButtonStyle` gets no dimming for free, so `.disabled(…)` used to leave a
                // dead button looking exactly like a live one.
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.easeOut(duration: DSAnimation.micro), value: configuration.isPressed)
                .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
                .onHover { isHovered = $0 }
        }

        /// Ghost takes `accentText`, not `accent`.
        ///
        /// A ghost button is nothing but its word, so that word is the entire control. The fill blue
        /// measured 3.65:1 on a sheet and 2.80:1 once the pointer lit the `accentSubtle` well beneath
        /// it — the label of the Cancel button in every sheet in the app, getting *harder* to read the
        /// moment you aimed at it. Every other variant sits on a slab and is unaffected.
        private var foreground: Color {
            switch variant {
            case .primary, .destructive: .white
            case .secondary: DSColors.labelPrimary
            case .ghost: DSColors.accentText
            }
        }

        /// Feedback is carried by the fill, not by a scale.
        ///
        /// The button used to grow 1.5% under the pointer and shrink 3% when pressed, and the whole
        /// thing was then clipped by a `clipShape` of the *unscaled* rounded rectangle applied
        /// outside the style — so hovering a bordered button visibly shaved its own border off.
        /// AppKit buttons do not change size when you point at them; they change colour.
        private var background: Color {
            switch variant {
            // `accentFill`, not `accent`: this is the one place the accent sits *behind white text*,
            // and the system blue measures 3.64:1 there. See the token for why only this moved.
            case .primary: shade(DSColors.accentFill)
            case .destructive: shade(DSColors.destructive)
            case .secondary: unfilled(rest: DSColors.tertiary)
            case .ghost: unfilled(rest: .clear)
            }
        }

        private var border: Color {
            switch variant {
            // The one variant that has to stay visible on a surface it may share a colour with.
            case .secondary: DSColors.border
            case .primary, .destructive, .ghost: .clear
            }
        }

        /// Filled variants darken on press and lift very slightly on hover.
        private func shade(_ base: Color) -> Color {
            if configuration.isPressed { return base.opacity(0.72) }
            return isHovered ? base.opacity(0.88) : base
        }

        /// Unfilled variants borrow the design system's established hover tint rather than inventing
        /// one — the same `accentSubtle` a panel header button lights up with.
        private func unfilled(rest: Color) -> Color {
            if configuration.isPressed { return DSColors.accentMuted }
            return isHovered ? DSColors.accentSubtle : rest
        }
    }
}
