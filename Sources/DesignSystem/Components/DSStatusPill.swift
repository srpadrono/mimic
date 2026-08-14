import SwiftUI

/// A status code (or the absence of one) as coloured text, filled only when it needs attention.
///
/// This was a convention before it was a component: six call sites hand-drew the same pill — the
/// request log row, the endpoint traffic list's rows and its header chips, the request detail's
/// identity row, the scenario list and the journey step row — and two of them disagreed about the
/// hardest case. A request that was failed rather than answered has no status code at all; the
/// traffic list drew it as a filled destructive em dash while the request log drew a bare grey `0`,
/// a status no server ever sent, styled as if it were ordinary. The em-dash treatment is the
/// defended one and the component carries it, so a site cannot re-decide it.
///
/// The rules, in one place:
///
/// - **The label colour comes from `DSColors.httpStatusColor(for:)`**, which returns the *text*
///   variants — the pill fills itself with a wash of its own label colour, and the base semantic
///   tokens do not survive that composite (see ``DSColors/warningText``).
/// - **Only a 4xx or 5xx is filled.** The house rule (skill `mimic-window-design`: "a filled colour swatch is for
///   something that needs attention") and also a contrast rule: a filled 3xx cannot clear AA on any
///   surface — 4.48:1 on a panel is its best — which is why `httpStatusColor(for:)`'s own comment
///   forbids filling one. The gate lives here so no call site can reopen that composite.
/// - **No code at all is a failure by definition, so it keeps the fill.** It renders as an em dash
///   in ``DSColors/destructiveText`` — never as `0`, which reads as a status the server actually
///   sent — and takes the text variant because the fill is a 12% tint of this very colour, where
///   the base red reads 4.07:1 on a panel.
/// - **The fill is `fillOpacity` (12%) of the label's own colour**, on a `DSCornerRadius.xs`
///   rectangle. `DSContrastTests.statusPillTextClearsAAOnItsOwnFill` measures exactly this
///   composite, on every bed the window puts a pill on — the selected and hovered rows included,
///   which are the beds that forced the text tokens to move twice.
/// - **Horizontal inset belongs to the fill; the vertical inset is paid on both** so a row does not
///   change height with its status code, and an unfilled code still aligns with the text around it.
///
/// Accessibility identifiers and labels are the call site's: the pill is addressed differently in
/// every panel (`requestDetail.status`, `endpointTraffic.status.<code>`), and most rows fold it
/// into one spoken label for the whole row.
public struct DSStatusPill: View {
    /// The fill is this much of the label's own colour. `DSContrastTests` measures the text tokens
    /// against exactly this wash; change one only with the other.
    public static let fillOpacity: Double = 0.12

    /// What a missing status code renders as. An em dash, never `0` — see the type's own comment.
    static let failureGlyph = "\u{2014}"

    let text: String
    let color: Color
    let isFilled: Bool

    /// A status pill for a response, or — when `statusCode` is nil — for a request that was failed
    /// rather than answered: a filled destructive em dash.
    public init(statusCode: Int?) {
        if let statusCode {
            text = "\(statusCode)"
            color = DSColors.httpStatusColor(for: statusCode)
            isFilled = statusCode >= 400
        } else {
            text = Self.failureGlyph
            color = DSColors.destructiveText
            isFilled = true
        }
    }

    /// A status pill with a trailing annotation — the traffic header's `"404 ×3"` chips.
    public init(statusCode: Int, detail: String) {
        text = "\(statusCode) \(detail)"
        color = DSColors.httpStatusColor(for: statusCode)
        isFilled = statusCode >= 400
    }

    /// A named failure ("drop", "timeout") in the failure arm's own styling: destructive text on a
    /// destructive tint, always filled — a failure is the thing the fill exists for.
    public init(failureLabel: String) {
        text = failureLabel
        color = DSColors.destructiveText
        isFilled = true
    }

    public var body: some View {
        Text(text)
            .font(DSTypography.codeSmall)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, isFilled ? DSSpacing.xs : 0)
            .padding(.vertical, 1)
            .background {
                if isFilled {
                    RoundedRectangle(cornerRadius: DSCornerRadius.xs)
                        .fill(color.opacity(Self.fillOpacity))
                }
            }
    }
}
