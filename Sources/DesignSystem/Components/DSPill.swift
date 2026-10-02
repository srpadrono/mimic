import SwiftUI

/// The look of a ``DSPill``: what fills it and what colours its text.
public enum DSPillTone {
    /// A quiet neutral fact: the field's fill, secondary text.
    case neutral
    /// Something to look at before going on: the warning wash, warning text.
    case warning
    /// A state in its own colour: a hairline outline and text in `tint`, no fill.
    case outline(Color)

    var foreground: Color {
        switch self {
        case .neutral: DSColors.labelSecondary
        case .warning: DSColors.warning
        case .outline(let tint): tint
        }
    }
}

/// The glyph a ``DSPill`` leads with.
public nonisolated enum DSPillGlyph {
    /// An SF Symbol at the pill's glyph size.
    case system(String)
    /// The design's dropped-connection glyph, ``DSConnectionDropGlyph``, at 11 pt.
    case connectionDrop
}

/// A short fact beside a row, as the design draws it on the journey step and import review boards:
/// an 18 pt capsule, 7 pt in from each end, 11 pt text.
///
/// For a pill whose content is drawn by the caller, such as a badge that changes on hover, use
/// ``SwiftUI/View/dsPill(_:)`` on that content instead.
public struct DSPill: View {
    private let text: String
    private let glyph: DSPillGlyph?
    private let tone: DSPillTone
    private let weight: Font.Weight

    public init(_ text: String, systemImage: String? = nil, tone: DSPillTone = .neutral,
                weight: Font.Weight = .regular) {
        self.init(text, glyph: systemImage.map { DSPillGlyph.system($0) }, tone: tone, weight: weight)
    }

    public init(_ text: String, glyph: DSPillGlyph?, tone: DSPillTone = .neutral,
                weight: Font.Weight = .regular) {
        self.text = text
        self.glyph = glyph
        self.tone = tone
        self.weight = weight
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xs) {
            switch glyph {
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: DSGlyph.disclosure))
                    .accessibilityHidden(true)
            case .connectionDrop:
                DSConnectionDropGlyph(size: DSGlyph.paneAction)
            case nil:
                EmptyView()
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(DSTypography.caption.weight(weight))
        .dsPill(tone)
    }
}

/// The pill's geometry, shared by ``DSPill`` and ``SwiftUI/View/dsPill(_:)``.
public enum DSPillMetrics {
    /// 18 pt: the capsule's height.
    public static let height: CGFloat = 18
    /// 7 pt: from each end of the capsule to its content.
    public static let horizontalPadding: CGFloat = 7
}

public extension View {
    /// Draws this content as a ``DSPill``: the capsule, its padding and the tone's colours. Text
    /// inside keeps any font it sets; otherwise it is 11 pt.
    func dsPill(_ tone: DSPillTone = .neutral) -> some View {
        modifier(DSPillChrome(tone: tone))
    }
}

private struct DSPillChrome: ViewModifier {
    let tone: DSPillTone

    func body(content: Content) -> some View {
        content
            .font(DSTypography.caption)
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, DSPillMetrics.horizontalPadding)
            .frame(height: DSPillMetrics.height)
            .background { fill }
    }

    @ViewBuilder
    private var fill: some View {
        switch tone {
        case .neutral:
            Capsule().fill(DSColors.field)
        case .warning:
            Capsule().fill(DSColors.warningBackground)
        case .outline(let tint):
            Capsule().strokeBorder(tint, lineWidth: DSStroke.hairline)
        }
    }
}
