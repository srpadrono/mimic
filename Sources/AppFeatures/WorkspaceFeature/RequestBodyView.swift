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
    /// Highlights every occurrence. Empty means no highlighting.
    let searchText: String
    let identifier: String

    @State private var rendered: Rendered?

    /// The formatted body plus what the formatter had to say about it.
    struct Rendered: Sendable, Equatable {
        var text: AttributedString
        var matchCount: Int
        /// `false` when the body was too large to format and is shown verbatim.
        var isFormatted: Bool
    }

    /// What `.task(id:)` watches. A struct rather than a concatenated string so recomputing does not
    /// mean building a second copy of a 64 KB body just to compare it.
    private struct RenderKey: Equatable {
        let payload: String
        let searchText: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            if let rendered {
                if !rendered.isFormatted {
                    Text("Shown unformatted — body is over \(JSONFormatter.formattingLimit / 1024) KB.")
                        .font(DSTypography.caption)
                        // `labelSecondary`. This is the sentence that explains why the payload below
                        // is a wall of minified JSON rather than the indented view every other body
                        // gets — without it the view looks broken. `DSContrastTests` asserts that
                        // `labelTertiary` clears AA on no surface in this app, in either appearance.
                        .foregroundStyle(DSColors.labelSecondary)
                }

                // The count lives here rather than next to the search field because only this view
                // knows what its own body contains — and "no matches" in the response is a useful
                // answer, not a failed search.
                if !searchText.isEmpty {
                    Text(Self.matchSummary(rendered.matchCount))
                        .font(DSTypography.caption)
                        // "No matches in this body" is the answer to a search someone just typed, so
                        // it is read rather than glanced past — the same reason the line above moved
                        // off `labelTertiary`. Still quieter than the hit count, which keeps
                        // `warning` because it is pointing at highlighted text further down.
                        .foregroundStyle(rendered.matchCount == 0 ? DSColors.labelSecondary : DSColors.warning)
                        .accessibilityIdentifier("requestLog.body.\(identifier).matches")
                }

                Text(rendered.text)
                    .font(DSTypography.codeSmall)
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
        // `DSColors.codeWell`, not a hand-written `tertiary.opacity(0.3)`. This was the literal that
        // put the syntax palette's contrast readings on a surface nothing paints: the token's comment
        // named `tertiary` — the opaque well `DSCodeBlock` fills with — while the only view in the app
        // that draws `DSColors.Syntax` is this one, on a 30% wash of it. Naming the composite is what
        // lets `DSContrastTests` measure the background this actually has.
        .background(DSColors.codeWell)
        .task(id: RenderKey(payload: payload, searchText: searchText)) {
            let payload = payload
            let searchText = searchText
            // Detached rather than a plain `await`: with approachable concurrency a nonisolated
            // async function stays on the caller's actor, and tokenising 64 KB on the main actor is
            // exactly the hitch this is meant to avoid.
            let result = await Task.detached {
                Self.render(payload: payload, searchText: searchText)
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

    nonisolated static func matchSummary(_ count: Int) -> String {
        count == 0 ? "No matches in this body" : "\(count) match\(count == 1 ? "" : "es")"
    }

    // MARK: - Rendering

    nonisolated static func render(payload: String, searchText: String) -> Rendered {
        let withinLimit = payload.utf8.count <= JSONFormatter.formattingLimit
        let formatted = withinLimit ? (JSONFormatter.prettyPrinted(payload) ?? payload) : payload

        var text = withinLimit ? coloured(formatted) : AttributedString(formatted)
        let matches = highlight(searchText, in: &text)

        return Rendered(text: text, matchCount: matches, isFormatted: withinLimit)
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

    /// Marks every occurrence of `term`, returning how many there were.
    ///
    /// **A hit takes a foreground as well as a background, and that pairing is the whole legibility of
    /// the feature.** This used to set `backgroundColor` alone and leave each run in whatever syntax
    /// colour `coloured(_:)` had given it — a saturated hue over a 35% amber wash. Composited and read
    /// back on `searchHit` over ``DSColors/codeWell`` over a panel, `key`, `string`, `number` and
    /// `literal` measured **4.28 / 3.22 / 3.08 / 3.06** in light and **2.29 / 3.21 / 3.64 / 2.62** in
    /// dark: eight readings, none of them at AA, on the one run of text the reader deliberately asked
    /// to find. `DSColors.Syntax.searchHitText` takes the worst of the same eight to 5.52.
    ///
    /// Order matters — `render(payload:searchText:)` colours first and highlights second, so this
    /// assignment is what wins on the runs it touches.
    @discardableResult
    nonisolated static func highlight(_ term: String, in text: inout AttributedString) -> Int {
        // An empty term matches at every index; without this guard the loop below never advances.
        guard !term.isEmpty else { return 0 }

        var matches = 0
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let found = text[searchStart...].range(of: term, options: .caseInsensitive) {
            text[found].backgroundColor = DSColors.Syntax.searchHit
            text[found].foregroundColor = DSColors.Syntax.searchHitText
            matches += 1
            searchStart = found.upperBound
        }

        return matches
    }
}
