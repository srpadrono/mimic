import SwiftUI

/// A row of icon tabs that swaps what a panel is showing.
///
/// Modelled on Xcode's navigator and inspector strips: the icons *are* the control, and only the
/// selected one is picked out — with a filled accent circle rather than a word. A segmented control
/// with labels in it is not affordable here. The sidebar is 220pt and the inspector 280pt, so three
/// or four text segments truncate on the first long noun and again on the first translation, while
/// icons stay legible at any width the user drags the panel to.
///
/// Two rules make it read as Xcode's strip rather than as a segmented control:
///
/// - **The selection background is a fixed 22pt circle**, never a share of the row. Filling the cell
///   instead is what the first attempt did, and two tabs in a 270pt sidebar became two 135pt tinted
///   slabs — unmistakably a segmented control.
/// - **The cells pack from the leading edge.** Xcode distributes its navigator icons because it has
///   nine to place; with two, an even split parks them at the 25% and 75% marks, which reads as two
///   buttons nobody aligned. Distribution only pays once a strip is crowded.
///
/// The accessory sits after a `Spacer`, so it holds the trailing edge whatever the tabs do.
///
/// It stands exactly as tall as `DSPanelHeader` and wears the same surface and bottom hairline, so
/// the two are interchangeable as panel chrome: a panel can open with a header, with a strip, or
/// with a strip under a header, and every panel in the window still lines up horizontally.
public struct DSTabStrip: View {
    /// One tab.
    ///
    /// Inert description, no behaviour — which is what lets a strip be built from a stored
    /// preference or a test fixture as readily as from a literal.
    public struct Tab: Identifiable, Equatable, Sendable {
        public let id: String
        public var systemImage: String
        /// Serves as the pointer tooltip *and* the VoiceOver label. An icon-only control has no
        /// other way to say what it does, and two separate strings for one meaning would drift.
        public var help: String
        /// `nil` — or zero — renders nothing. Anything higher is a count the tab wants noticed.
        public var badge: Int?

        public init(id: String, systemImage: String, help: String, badge: Int? = nil) {
            self.id = id
            self.systemImage = systemImage
            self.help = help
            self.badge = badge
        }
    }

    private let tabs: [Tab]
    @Binding private var selection: String
    private let identifier: String
    private let accessory: AnyView?
    /// Whether the strip draws its own bar: 30pt height, `secondary` surface, and the 0.5pt bottom
    /// rule every panel header ends with.
    ///
    /// `false` when the strip is dropped into another bar's accessory slot. `InspectorPanelView`
    /// nests one inside a `DSPanelHeader`, which already draws all three — so the hairline was
    /// composited with itself, whatever `DSColors.separator` happens to be, and the inspector's
    /// bottom edge was visibly heavier under the tabs than under the title beside them, with a hard
    /// edge where the strip ended.
    private let drawsChrome: Bool

    public init(tabs: [Tab], selection: Binding<String>, identifier: String, drawsChrome: Bool = true) {
        self.tabs = tabs
        self._selection = selection
        self.identifier = identifier
        self.accessory = nil
        self.drawsChrome = drawsChrome
    }

    /// With a trailing control — an "add" button, usually.
    ///
    /// The alternative was a `DSPanelHeader` stacked above the strip, which is what this replaced:
    /// two 30pt rows of chrome before a 270pt sidebar showed a single endpoint. One row carries both
    /// because the selected tab already says which list you are looking at, so a title repeating it
    /// was paying height for nothing.
    ///
    /// `AnyView` rather than a generic parameter so the two call sites can pass different accessory
    /// types without the strip's type changing underneath them — the erasure costs one allocation on
    /// a view that redraws when a tab changes, which is not a hot path.
    public init<Accessory: View>(
        tabs: [Tab],
        selection: Binding<String>,
        identifier: String,
        drawsChrome: Bool = true,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.tabs = tabs
        self._selection = selection
        self.identifier = identifier
        self.accessory = AnyView(accessory())
        self.drawsChrome = drawsChrome
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xxs) {
            ForEach(tabs) { tab in
                TabButton(
                    tab: tab,
                    isSelected: tab.id == selection,
                    identifier: "\(identifier).tab.\(tab.id)"
                ) {
                    selection = tab.id
                }
            }

            // Packed from the leading edge, not distributed. Xcode distributes because it has nine
            // navigators to place; with two, an even split parks them at the 25% and 75% marks,
            // which reads as two arbitrarily positioned buttons rather than a strip. Distribution
            // and packing only differ once a strip is crowded, and neither of ours is.
            //
            // This is safe now in a way it was not before: the selection shape is a fixed 22pt
            // circle, so packing no longer drags a stretched tinted slab along with it.
            Spacer(minLength: 0)

            accessory
        }
        // Asymmetric, and measured rather than assumed. `xs` on the leading edge looks 8pt short of
        // the `md` every other bar insets by, but a tab is a 13pt glyph centred in a 22pt circle
        // centred in a 28pt cell: at `xs` the glyph's own ink starts at 11.5pt, against 12.75pt for a
        // panel header's title. It is already on the column. Moving the padding to `md` would put the
        // ink at 19.5 and break the alignment it looks like it is fixing.
        //
        // The trailing edge had no such excuse. The accessory is a `DSPanelHeaderButton`, the same
        // 22pt target the run strip directly below this one carries — and that strip insets by `md`,
        // so the sidebar's "+" and the run controls under it sat 8pt apart in the same column while
        // the run strip's own note claimed they lined up. Only when the strip draws its own bar: a
        // nested one sits in a `DSPanelHeader`'s accessory slot, which has already paid the inset.
        .padding(.leading, DSSpacing.xs)
        .padding(.trailing, drawsChrome ? DSSpacing.md : DSSpacing.xs)
        .padding(.vertical, DSSpacing.xs)
        .frame(height: drawsChrome ? DSBarHeight.panelHeader : nil)
        .background(drawsChrome ? DSColors.secondary : Color.clear)
        .overlay(alignment: .bottom) {
            if drawsChrome {
                Rectangle()
                    .fill(DSColors.separator)
                    .frame(height: 0.5)
            }
        }
        // Paired deliberately. A bare identifier on a container makes every descendant report the
        // container's name instead of its own, and each `…tab.…` query in the UI suite would come
        // back empty for reasons that look nothing like the cause.
        .accessibilityIdentifier("ds.tabstrip.\(identifier)")
        .accessibilityElement(children: .contain)
    }

    /// Its own view so hover state stays local. Held on the strip as a `hoveredID`, one pointer
    /// crossing the row would re-evaluate every tab in it.
    private struct TabButton: View {
        let tab: DSTabStrip.Tab
        let isSelected: Bool
        let identifier: String
        let select: () -> Void

        @State private var isHovered = false

        /// The selection circle's diameter, and the icon's whole footprint. Fixed, whatever share of
        /// the row the cell gets.
        private static let shapeSize: CGFloat = 22

        var body: some View {
            Button(action: select) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: Self.shapeSize, height: Self.shapeSize)
                    .background(Circle().fill(selectionFill))
                    .overlay(alignment: .topTrailing) { badge }
                    // A cell just wider than the shape, not a share of the row. Letting it expand
                    // spread two tabs to the 25% and 75% marks of the sidebar, which reads as two
                    // buttons someone forgot to align rather than as a strip.
                    .frame(width: Self.shapeSize + DSSpacing.sm)
                    // The whole cell is the target, so the pointer does not have to find a 22pt
                    // circle inside it.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
            .help(tab.help)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(tab.help)
            // The badge rides in the value rather than the label so the label stays a stable string
            // a test can assert on while the count moves underneath it.
            .accessibilityValue(badgeAnnouncement)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }

        /// Rides the corner of the selection shape rather than sitting beside the icon.
        ///
        /// Inline, it widened the cell by its own width, so the icon drifted off centre the moment a
        /// count appeared and drifted back when it cleared — the strip visibly shuffled while you
        /// watched it. As an overlay it takes no part in layout, so a badged tab and a bare one are
        /// the same shape.
        @ViewBuilder
        private var badge: some View {
            // A dot, not a number — and that is the Xcode-faithful answer as well as the legible
            // one. Xcode's navigator tabs carry no counts; its counts live in the toolbar, where
            // there is room for them. On a 22pt circle a three-character badge ("99+") covered the
            // glyph it was annotating, so the tab could tell you there were 128 of something or
            // show you which something, but not both.
            //
            // Nothing is lost: the exact count is announced through `.accessibilityValue`, and
            // every surface that badges a tab already states the number in its own header — the
            // traffic list opens with "128 requests".
            Group {
                if hasBadge {
                    Circle()
                        .fill(DSColors.httpStatusColor(for: 404))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(DSColors.secondary, lineWidth: 1.5))
                        .offset(x: 3, y: -1)
                        .allowsHitTesting(false)
                }
            }
        }

        /// Xcode's selected navigator tab is a solid accent circle, not a tint behind a coloured
        /// glyph — at 12% accent the selection was legible in a screenshot and easy to lose in a
        /// window. Hover gets its own fill so an unselected tab still shows where the target is.
        private var selectionFill: Color {
            if isSelected { return DSColors.accent }
            return isHovered ? DSColors.accentSubtle : .clear
        }

        /// An unselected tab is still a control you are meant to find. At `labelTertiary` — 36%
        /// alpha — the second navigator icon was barely visible against the panel, so the strip read
        /// as one button and a smudge. Xcode's unselected navigator glyphs sit around 55–60%.
        private var iconColor: Color {
            if isSelected { return .white }
            return isHovered ? DSColors.labelPrimary : DSColors.labelSecondary
        }

        /// Capped, because the badge overlays the corner of a 22pt circle — four digits would reach
        /// across the icon it is annotating and into the next tab's share of the row.
        private var hasBadge: Bool {
            (tab.badge ?? 0) > 0
        }

        /// The real number, not the capped one: "99+" is a layout compromise, and VoiceOver has no
        /// column to run out of.
        private var badgeAnnouncement: String {
            guard let badge = tab.badge, badge > 0 else { return "" }
            return "\(badge)"
        }
    }
}
