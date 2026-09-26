import SwiftUI

/// The divider between two groups of rows inside a panel — a label for what follows, not a headline.
///
/// Modelled on Xcode's inspector section headers, which are the smallest thing on screen that still
/// reads as structure: 13pt, `secondary`-weight, sentence case, on a faintly tinted band with a
/// hairline under it. This one used to be 13pt medium on the panel's own background, which put the
/// header at the same visual weight as the values underneath it — so an inspector read as a wall of
/// equally loud rows and you had to actually read a line to find out whether it was a heading.
///
/// The band does the separating, which is why the type can be this quiet. Take the band away and the
/// weight has to come back into the text.
///
/// **The title renders exactly as given.** No `.textCase`: every call site already passes sentence
/// case ("Response headers", "Answered by"), and a component that shouts them back in caps makes the
/// strings at the call sites a lie about what appears on screen.
public struct DSSectionHeader<Trailing: View>: View {
    private let title: String
    private let identifier: String
    private let trailingAction: Trailing?

    public init(
        _ title: String,
        identifier: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.identifier = identifier
        self.trailingAction = trailing()
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(DSTypography.labelMedium)
                .foregroundStyle(DSColors.labelSecondary)

            Spacer()

            if let trailingAction {
                trailingAction
            }
        }
        .padding(.horizontal, DSSpacing.md)
        // Four points keep the 13pt label clear of the hairline; the minimum height below sets the
        // bar's rhythm, including the taller variant with an action.
        .padding(.vertical, DSSpacing.xs + 1)
        // A floor, not a fixed height, because this header has two honest sizes and both are rungs:
        // bare it measures 28 (`secondaryBar`), and with a trailing action it grows to the 36pt
        // control row. A fixed bare height would clip the action when a pane is narrow.
        .frame(minHeight: trailingAction == nil ? DSBarHeight.secondaryBar : DSBarHeight.controlRow)
        // Faint on purpose: enough to separate the header from the rows below without becoming a
        // second surface inside a panel that is already an elevated one. `band`, whose note explains
        // why it blends toward `tertiary` — the panel's own surface *is* secondary, so a wash of
        // secondary was a band against itself: invisible, and the sections ran together as one
        // undifferentiated list.
        .background(DSColors.band)
        .overlay(alignment: .bottom) {
            Rectangle()
                // `separator` at full strength, not `separator.opacity(0.6)`. The latter lands at
                // ~7% alpha, which on this surface is a rule you cannot see — and the same header
                // rendered in two panels was then ending a section visibly in one and invisibly in
                // the other. Not `panelSeparator` either: that is heavier, and it is reserved for
                // the seam *between* panels. This is a bar inside one.
                .fill(DSColors.separator)
                .frame(height: DSStroke.hairline)
        }
        // Paired, because this header carries a trailing control slot — "Add" and "Format" both
        // live there. A container identifier with no `.contain` renames every descendant to match
        // it, and those buttons stop being addressable by their own names.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.sectionheader.\(identifier)")
    }
}

extension DSSectionHeader where Trailing == EmptyView {
    public init(_ title: String, identifier: String) {
        self.title = title
        self.identifier = identifier
        self.trailingAction = nil
    }
}
