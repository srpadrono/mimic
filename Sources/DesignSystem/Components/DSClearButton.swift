import SwiftUI

/// The `⊗` that empties a search field.
///
/// One type, because the window has exactly one of this job and used to draw it twice: `DSFilterField`
/// and the request detail's "Find in body" both put an `xmark.circle.fill` in an 18×18 well inside a
/// 20pt track, one at 11pt and one at 10pt, and only one of them answered the pointer. Each carried a
/// comment claiming to match the other — they matched on the frame, which is the part nobody notices,
/// and differed on the glyph and the hover, which are the parts you do.
///
/// **Present only while there is something to clear**, so neither field carries a permanently dead
/// affordance — and its own view so the hover highlight redraws the button rather than the text field
/// it sits beside.
///
/// **Hover is a colour change, not a well.** Every other icon button in the window lights up with an
/// `accentSubtle` rounded rect, and this is the one place that cannot: the button is 18pt inside a
/// 20pt track that already has a fill and a hairline, so a second well would leave a 1pt margin and
/// read as a control that had come loose from its field. The glyph going from `labelSecondary` to
/// `labelPrimary` is the whole response, which is what `DSPanelHeaderButton` does with its own glyph.
///
/// The strings are parameters rather than constants because the two fields filter different things —
/// "Clear filter" and "Clear the search" are the names a UI test already knows them by.
public struct DSClearButton: View {
    @Binding private var text: String
    private let identifier: String
    private let label: String
    private let help: String

    /// - Parameters:
    ///   - identifier: Used verbatim, not suffixed. `DSFilterField` hands in `"<field>.clear"` and the
    ///     request detail hands in its own name, so neither call site's accessibility identifier moves.
    ///   - label: What VoiceOver reads. The glyph says nothing on its own.
    ///   - help: The tooltip.
    public init(
        text: Binding<String>,
        identifier: String,
        label: String,
        help: String
    ) {
        self._text = text
        self.identifier = identifier
        self.label = label
        self.help = help
    }

    @State private var isHovered = false

    public var body: some View {
        Button { text = "" } label: {
            // The target is on the label, not the glyph: a bare `Image` in a `.plain` button gives a
            // ~10pt hit area, the shape the panel-chrome rules name as too small to aim at. 11pt is
            // the control-glyph floor — 10 put this below the inline glyphs it sits beside.
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(isHovered ? DSColors.labelPrimary : DSColors.labelSecondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }
}
