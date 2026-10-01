import SwiftUI
import DesignSystem

/// A request or response body, laid out so it can actually be read.
///
/// The previous rendering put the raw body in a horizontal `ScrollView` with a single `Text`, which
/// meant a minified JSON payload — which is what a mock returns almost every time — arrived as one
/// endless line you scrolled sideways through. Here the body is re-indented, coloured, and wrapped,
/// so the shape of the payload is visible at a glance and long values break instead of running off
/// the edge.
struct RequestBodyView: View {
    let payload: String
    let identifier: String

    @State private var rendered: Rendered?

    /// The formatted body plus what the formatter had to say about it.
    struct Rendered: Sendable, Equatable {
        var text: AttributedString
        /// `false` when formatting would make the body too large, or the input limit was exceeded.
        var isFormatted: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            if let rendered {
                if !rendered.isFormatted {
                    Text(payload.utf8.count > JSONFormatter.formattingLimit
                         ? "Shown unformatted — body is over \(JSONFormatter.formattingLimit / 1024) KB."
                         : "Shown unformatted — body would be too large when indented.")
                        .font(DSTypography.callout)
                        .lineSpacing(DSSpacing.xxs)
                        // Secondary, not tertiary: it explains why the payload is not indented.
                        .foregroundStyle(DSColors.labelSecondary)
                        .accessibilityIdentifier("requestLog.body.\(identifier).unformatted")
                }

                Text(rendered.text)
                    .font(DSTypography.code)
                    .lineSpacing(DSSpacing.xxs)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Take the full height the wrapped text needs. Inside a `ScrollView` the text
                    // would otherwise be handed a proposed height and truncate to it, which is the
                    // vertical version of the bug this view exists to fix.
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("requestLog.body.\(identifier)")
            } else {
                // Only ever seen for a body large enough to take a frame to format.
                DSLoadingPlaceholder(identifier: "requestLog.body.\(identifier)")
            }
        }
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The code surface the syntax colours are measured against, as a rounded well.
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.field)
                .fill(DSColors.code)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DSCornerRadius.field)
                .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
        }
        .task(id: payload) {
            let payload = payload
            // Detached rather than a plain `await`: with approachable concurrency a nonisolated
            // async function stays on the caller's actor, and tokenising 64 KB on the main actor is
            // exactly the hitch this is meant to avoid.
            let result = await Task.detached {
                Self.render(payload: payload)
            }.value
            // Awaiting a non-throwing detached task swallows the cancellation `.task(id:)` sent
            // when the id changed, so a slow render of the previous body could come back after the
            // new one and sit on screen until the id next moved. Land only the render still asked
            // for — the same guard the detached hops in `SidebarView` and `RequestLogDrawerView`
            // close with.
            if !Task.isCancelled {
                rendered = result
            }
        }
    }

    // MARK: - Rendering

    nonisolated static func render(payload: String) -> Rendered {
        let withinLimit = payload.utf8.count <= JSONFormatter.formattingLimit
        let pretty = withinLimit ? JSONFormatter.prettyPrinted(payload) : nil
        let formatted = pretty ?? payload
        // A body already laid out across lines is deliberately preserved. A compact JSON-shaped
        // body whose indentation exceeded the formatter's budget needs an honest fallback label.
        let expansionRejected = withinLimit && pretty == nil
            && JSONFormatter.looksLikeJSON(payload)
            && !payload.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D })

        let text = withinLimit ? coloured(formatted) : AttributedString(formatted)
        return Rendered(text: text, isFormatted: withinLimit && !expansionRejected)
    }

    nonisolated static func coloured(_ text: String) -> AttributedString {
        var result = AttributedString()
        for token in JSONFormatter.tokenize(text) {
            var run = AttributedString(token.text)
            run.foregroundColor = color(for: token.kind)
            result.append(run)
        }
        return result
    }

    nonisolated static func color(for kind: JSONFormatter.TokenKind) -> Color {
        switch kind {
        case .key: DSColors.Syntax.key
        case .string: DSColors.Syntax.string
        case .number: DSColors.Syntax.number
        case .literal: DSColors.Syntax.literal
        case .punctuation: DSColors.Syntax.punctuation
        case .plain: DSColors.labelPrimary
        }
    }
}
