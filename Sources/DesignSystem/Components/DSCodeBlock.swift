import SwiftUI

/// A block of code in a recessed well: monospaced, selectable, and scrollable sideways when a line
/// runs past the edge.
///
/// **The scroller is not hidden.** A horizontally scrolling region with no indicator gives the
/// reader nothing to tell "the line ends here" from "the line continues past the edge", so a base URL
/// clipped mid-host read as a rendering fault rather than as something to scroll. `.automatic` is
/// the macOS behaviour: an overlay scroller while you scroll, and nothing when the content fits.
/// (It also replaces `ScrollView(_:showsIndicators:)`, which is deprecated.)
///
/// The well is the same construction as `DSTextField` and `DSFilterField` — `DSColors.tertiary`
/// behind a 0.5pt `DSColors.border` hairline at `DSCornerRadius.sm`, with `DSSpacing.sm` of inset —
/// so a code block and a text field sitting in the same sheet are recognisably the same kind of
/// surface. The inset used to be `DSSpacing.sm + 2` on one axis only, which is not a token and did
/// not match anything.
public struct DSCodeBlock: View {
    private let content: String
    private let identifier: String

    public init(_ content: String, identifier: String) {
        self.content = content
        self.identifier = identifier
    }

    public var body: some View {
        ScrollView(.horizontal) {
            Text(content)
                .font(DSTypography.code)
                .foregroundStyle(DSColors.labelPrimary)
                .textSelection(.enabled)
        }
        .scrollIndicators(.automatic)
        .padding(DSSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                .fill(DSColors.tertiary)
        }
        .overlay {
            // `strokeBorder`, not `stroke`: a centred stroke puts half its width outside the shape,
            // where it either overlaps whatever is next to the block or gets clipped away by an
            // ancestor. Inset, the whole hairline is drawn and it is drawn where the fill ends.
            RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                .strokeBorder(DSColors.border, lineWidth: 0.5)
        }
        .accessibilityIdentifier("ds.code.\(identifier)")
        .accessibilityLabel(content)
    }
}
