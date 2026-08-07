import SwiftUI

/// An HTTP status code, as coloured text or — only when it is a failure — a filled swatch.
///
/// This rule was implemented four times before this component existed: in the request log's rows, the
/// inspector's endpoint traffic list, the journey step row and the scenario list. All four agreed on
/// `>= 400` and on a 12% fill, and they agreed by coincidence rather than by construction — one of
/// them also inset its *unfilled* codes, so a column of 200s in the scenario list started four points
/// further right than the same column in the traffic list.
///
/// **Only failures take the fill.** Every row has a status, so filling all of them makes a column of
/// swatches in which nothing stands out — the opposite of what colour on a status code is for. Each
/// of the four call sites had independently written a comment saying exactly that, which is a good
/// sign the rule is right and a better sign it belonged in one place.
///
/// **The text on a filled swatch is the *deep* variant, and that is not cosmetic.** A hue on a tint
/// of itself is the construction this palette keeps failing: plain `destructive` on its own 12% fill
/// measures 3.99:1 over `surfaceSidebar` in light, and plain `warning` measures 4.00:1. Both were
/// already shipping below the floor. `warningDeep` and `destructiveDeep` exist for exactly this.
public struct DSStatusCodeBadge: View {
    /// What the badge is describing, since not every outcome has a number.
    public enum Outcome: Equatable, Sendable {
        /// A real HTTP status code.
        case code(Int)
        /// The connection failed before a status existed — a journey's transport failure, or a
        /// request the engine never answered.
        ///
        /// Rendered as a word rather than a number, because no status code expresses it and inventing
        /// one (0, or 499) reads as a real response to anyone scanning the column.
        case transportFailure
        /// Nothing was recorded. An em dash, quiet.
        case none
    }

    private let outcome: Outcome
    private let identifier: String

    public init(_ outcome: Outcome, identifier: String) {
        self.outcome = outcome
        self.identifier = identifier
    }

    public init(code: Int, identifier: String) {
        self.init(.code(code), identifier: identifier)
    }

    /// 14%, not the 12% the four copies used and not the 16% the redesign specifies. 12% left both
    /// failure hues below 4.5:1 with their deep text; 16% is darker still. 14% is the most fill the
    /// swatch can carry while `destructiveDeep` clears the floor on every surface in both appearances.
    private static let fillAlpha: Double = 0.14

    public var body: some View {
        content
            .font(DSTypography.Figure.status)
            .lineLimit(1)
            .padding(.horizontal, isFilled ? DSSpacing.xs : 0)
            .padding(.vertical, 1)
            .background {
                if isFilled {
                    RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                        .fill(fillColor.opacity(Self.fillAlpha))
                }
            }
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(spokenLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch outcome {
        case let .code(code):
            Text("\(code)").foregroundStyle(textColor)
        case .transportFailure:
            Text("drop").foregroundStyle(DSColors.destructiveDeep)
        case .none:
            Text("\u{2014}").foregroundStyle(DSColors.labelTertiary)
        }
    }

    private var isFilled: Bool {
        switch outcome {
        case let .code(code): code >= 400
        case .transportFailure: true
        case .none: false
        }
    }

    /// The hue the fill is tinted with — the plain semantic, since the fill is a wash and not text.
    private var fillColor: Color {
        switch outcome {
        case let .code(code): DSColors.httpStatusColor(for: code)
        case .transportFailure: DSColors.destructive
        case .none: .clear
        }
    }

    /// The hue the *text* takes. On a filled swatch this is the deep variant; unfilled it is the
    /// plain semantic, which is measured against the row surface rather than against a tint.
    private var textColor: Color {
        guard case let .code(code) = outcome else { return DSColors.labelTertiary }
        switch code {
        case 400..<500: return DSColors.warningDeep
        case 500..<600: return DSColors.destructiveDeep
        default: return DSColors.httpStatusColor(for: code)
        }
    }

    /// VoiceOver reads the class, not just the digits. "404" is three numbers; "404, client error"
    /// is the thing the colour is telling a sighted user.
    private var spokenLabel: String {
        switch outcome {
        case let .code(code):
            switch code {
            case 200..<300: "\(code), success"
            case 300..<400: "\(code), redirect"
            case 400..<500: "\(code), client error"
            case 500..<600: "\(code), server error"
            default: "\(code)"
            }
        case .transportFailure: "Connection dropped"
        case .none: "No status"
        }
    }
}
