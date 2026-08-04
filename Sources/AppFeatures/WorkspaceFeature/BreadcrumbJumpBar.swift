import SwiftUI
import DesignSystem

/// The jump bar above the centre pane: where you are, and a way to go somewhere else without
/// travelling back through the sidebar.
///
/// The editor already showed a breadcrumb — the endpoint's group tag, rendered as a caption. It told
/// you where you were and did nothing else, which is the least useful half of a breadcrumb. Xcode's
/// jump bar is the shape worth copying: every segment is a menu, so `project ▸ group ▸ file ▸ symbol`
/// doubles as four sideways moves. Switching to the sibling endpoint in the same group costs one
/// click here instead of a trip to the sidebar, a scroll, and a hunt.
///
/// The chrome rules are deliberately not `DSPanelHeader`'s:
///
/// - **24pt, not 30.** This sits *inside* the editor rather than above a panel. Matching the panel
///   header height would make it read as a fourth panel header and put two same-weight bars in a row
///   at the top of the window. Secondary chrome should look secondary — but it still has to be
///   readable, and 22pt was too short to sit 11pt text in without it feeling wedged.
/// - **Secondary is not disabled.** The whole bar once rendered at caption weight in the secondary
///   label colour, which read as greyed-out chrome. Crumbs are 11pt; the trailing crumb — where you
///   actually are — takes the primary label colour at medium weight, as Xcode's does.
/// - **A crumb with nowhere to go is not a control.** Zero options renders as plain text — no hover
///   response, no menu indicator — because a button that does nothing when clicked is worse than a
///   label. A crumb that *does* have options says so before you hover, with the same
///   `chevron.up.chevron.down` Xcode puts on its jump-bar segments.
/// - **The separators are punctuation.** The chevrons between crumbs are 8pt, tertiary, and hidden
///   from VoiceOver: they are the `▸` in the path, not something you can press.
/// - **The bar never widens the window.** Every crumb is single-line and capped, and the trail is
///   the row's only flexible element, so a long path clips instead of pushing the editor's minimum
///   width out.
struct BreadcrumbJumpBar: View {
    /// Deliberately shorter than `DSBarHeight.panelHeader`, but tall enough for 11pt crumbs. See the
    /// type's note — `secondaryBar` is the rung that exists for this bar.
    static var height: CGFloat { DSBarHeight.secondaryBar }

    /// One level of the path.
    struct Crumb: Identifiable, Equatable {
        /// Stable per *level*, not per value — "group", "endpoint", "scenario". The bar hands it back
        /// with the chosen option so the caller knows which level moved, and it keeps the
        /// accessibility identifier steady while the title underneath changes.
        let id: String
        var title: String
        /// Optional leading glyph, e.g. `folder` for a group.
        var systemImage: String?
        /// Empty means this level has no siblings worth offering, so it renders as a label.
        var options: [Option]

        init(id: String, title: String, systemImage: String? = nil, options: [Option] = []) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            self.options = options
        }
    }

    /// A sideways move available from one crumb.
    struct Option: Identifiable, Equatable {
        let id: UUID
        var title: String
        var isSelected: Bool

        init(id: UUID = UUID(), title: String, isSelected: Bool = false) {
            self.id = id
            self.title = title
            self.isSelected = isSelected
        }
    }

    let crumbs: [Crumb]
    let canGoBack: Bool
    let canGoForward: Bool
    /// (crumb id, chosen option id)
    let onSelectOption: (String, UUID) -> Void
    let onBack: () -> Void
    let onForward: () -> Void

    init(
        crumbs: [Crumb],
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        onSelectOption: @escaping (String, UUID) -> Void,
        onBack: @escaping () -> Void = {},
        onForward: @escaping () -> Void = {}
    ) {
        self.crumbs = crumbs
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.onSelectOption = onSelectOption
        self.onBack = onBack
        self.onForward = onForward
    }

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            BreadcrumbHistoryButton(
                systemImage: "chevron.left",
                label: "Go back",
                identifier: "breadcrumb.back",
                isEnabled: canGoBack,
                action: onBack
            )

            BreadcrumbHistoryButton(
                systemImage: "chevron.right",
                label: "Go forward",
                identifier: "breadcrumb.forward",
                isEnabled: canGoForward,
                action: onForward
            )

            HStack(spacing: DSSpacing.xs) {
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { pair in
                    if pair.offset > 0 {
                        BreadcrumbSeparator()
                    }

                    BreadcrumbCrumbView(
                        crumb: pair.element,
                        isLast: pair.offset == crumbs.count - 1,
                        onSelect: { optionID in onSelectOption(pair.element.id, optionID) }
                    )
                }
            }

            // A `Spacer` absorbs the slack so the crumbs hug the leading edge. Note what this is
            // *not*: the original paired this `Spacer` with `.layoutPriority(-1)` on the trail, and
            // a `Spacer` claims slack at default priority — so the trail was proposed nothing and
            // the crumbs collapsed instead of truncating. Replacing that with
            // `.frame(maxWidth: .infinity)` fixed the collapse and caused the opposite fault: with
            // the trail greedy, each title's 200pt cap became its actual width and the path rendered
            // as widely-spaced words.
            //
            // Neither element is greedy now. The crumbs size to their content, the cap only bites on
            // a genuinely long name, and the `Spacer` takes whatever is left — which also keeps a
            // deep path from reporting a large minimum width and dragging the window wider.
            Spacer(minLength: 0)
        }
        // `md`, matching every other bar's inset. At `sm` this one was inset 6 while everything
        // under it was inset 12, which read as the bar being slightly out of true.
        //
        // Note what this does *not* claim: the first crumb does not land on the editor header's x.
        // The two history arrows come first, so the trail starts ~44pt further in. That is Xcode's
        // jump bar too — its path also begins after its back/forward pair — so the offset is the
        // shape of the control, not a misalignment to chase.
        .padding(.horizontal, DSSpacing.md)
        .frame(height: Self.height)
        // `band`, the one surface for a bar that sits inside a pane. This was `secondary.opacity(0.5)`
        // — a half-wash of the panel-header surface, which is the tone this bar's own note says it
        // must not be mistaken for. Half of it is still a step towards it, and over the editor canvas
        // it landed within a hair of `surfaceElevated` for no reason anyone had written down.
        .background(DSColors.band)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DSColors.separator)
                .frame(height: 0.5)
        }
        .clipped()
        .accessibilityIdentifier("breadcrumb")
        // Mandatory partner to the identifier above: naming a container otherwise renames every
        // element inside it, and `breadcrumb.crumb.*` would vanish from the accessibility tree.
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Crumb

/// One level of the path: a menu when it has somewhere to send you, a label when it does not.
private struct BreadcrumbCrumbView: View {
    let crumb: BreadcrumbJumpBar.Crumb
    /// The last crumb is where you are, so it carries the primary label colour.
    let isLast: Bool
    let onSelect: (UUID) -> Void

    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        if crumb.options.isEmpty {
            content(color: restingColor)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("breadcrumb.crumb.\(crumb.id)")
                .accessibilityLabel(crumb.title)
        } else {
            Menu {
                ForEach(crumb.options) { option in
                    Button {
                        onSelect(option.id)
                    } label: {
                        // A checkmark rather than a tint, so the current choice survives
                        // Differentiate Without Color.
                        if option.isSelected {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                    .accessibilityIdentifier("breadcrumb.option.\(option.id.uuidString)")
                    .accessibilityLabel(option.isSelected ? "\(option.title), selected" : option.title)
                }
            } label: {
                content(color: isHovered ? DSColors.labelPrimary : restingColor)
            }
            // Styled to read as text: the crumb has to look like part of a path.
            //
            // `.button` + `.plain`, not `.borderlessButton`. A borderless *menu* is realised as an
            // `NSPopUpButton`, which draws its own indicator *before* the label and ignores
            // `.menuIndicator(.hidden)` — on screen that put a stray chevron in front of every
            // clickable crumb and swallowed the compact one `content` draws after the title.
            //
            // The `.plain` half is the shared rule, not a local quirk: `DSFilterField.ScopeMenu` is
            // the app's other hand-styled menu and now wears the identical pairing. Both labels draw
            // all of their own chrome, so the button style has to add none — `.borderless` would put
            // the system accent back on content that states its own colour. The two used to differ by
            // that one word, each with a comment defending itself, and nothing tracked the difference.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            // No `.fixedSize()`. It proposes an unbounded width to the label, which makes the
            // title's `maxWidth` cap resolve to the cap itself — every crumb then occupied 200pt and
            // the trail read as widely-spaced words rather than a path. Without it the crumb takes
            // its natural width and the cap only bites on a genuinely long name.
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
            .help(crumb.title)
            .accessibilityIdentifier("breadcrumb.crumb.\(crumb.id)")
            .accessibilityLabel(crumb.title)
        }
    }

    private var restingColor: Color {
        isLast ? DSColors.labelPrimary : DSColors.labelSecondary
    }

    private func content(color: Color) -> some View {
        HStack(spacing: DSSpacing.xxs) {
            if let systemImage = crumb.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .medium))
                    .accessibilityHidden(true)
            }

            // 11pt, not the 10pt caption: a path you cannot read at a glance is decoration. The
            // crumb you are on carries medium weight so the end of the path is the part that reads
            // first — the one place in this file `fontWeight` earns itself.
            Text(crumb.title)
                .font(DSTypography.label)
                .fontWeight(isLast ? .medium : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
                // No `.frame(maxWidth:)`. `maxWidth` caps *and* expands: given a row with slack it
                // made every crumb 200pt wide, and the path rendered as widely-spaced words rather
                // than a trail. A plain `Text` with `.lineLimit(1)` already does what is wanted —
                // it reports its ideal width, takes no more, and truncates when the row runs out.
                // The bar's `.clipped()` is what stops a very long name overflowing.

            // The affordance, drawn only where there is somewhere to go. Deliberately tertiary and
            // 8pt: it marks the crumb as pressable without competing with the title it follows.
            if crumb.options.isEmpty == false {
                Image(systemName: "chevron.up.chevron.down")
                    // 8pt, the floor. At 7 the affordance that says "this crumb is a menu" was a
                    // smudge, which is the same as not having it.
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DSColors.labelTertiary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(color)
    }
}

// MARK: - Separator

/// The `▸` between two crumbs. Punctuation, not a control — hence hidden from VoiceOver, which
/// would otherwise read "chevron right" between every level of the path.
private struct BreadcrumbSeparator: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(DSColors.labelTertiary)
            .accessibilityHidden(true)
    }
}

// MARK: - History controls

/// A back or forward arrow, sized for the 24pt bar.
///
/// The icon is a `Label` with the text styled away rather than a bare `Image`, so VoiceOver and Voice
/// Control still have something to say, and the 18pt frame plus `contentShape` gives it a hit target
/// rather than the ~10pt the glyph would offer on its own.
private struct BreadcrumbHistoryButton: View {
    let systemImage: String
    let label: String
    let identifier: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 18, height: 18)
                .background(
                    // `sm`, like every other hover well in the window — `DSHoverModifier`, the sidebar rows,
                // the scenario rows, `DSPanelHeaderButton` and the editor's more menu all use it. This
                // was the only one at `xs`.
                RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                        .fill(isHovered && isEnabled ? DSColors.accentSubtle : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help(label)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }

    private var foreground: Color {
        // `labelTertiary` alone. Compounding it with `.opacity(0.4)` gave 14% effective alpha —
        // below AppKit's own ~25% `disabledControlTextText`, where a control stops reading as
        // disabled and starts reading as a drawing glitch.
        guard isEnabled else { return DSColors.labelTertiary }
        return isHovered ? DSColors.labelPrimary : DSColors.labelSecondary
    }
}

// MARK: - Navigation history

/// Back/forward history for the centre pane, in the shape a browser uses.
///
/// `nonisolated` because this is arithmetic over an array: it has no actor affinity, and keeping it
/// off the main actor means it can be exercised as a plain value in tests rather than through a view.
///
/// Two rules make it feel like a browser rather than an undo stack: a new visit throws away
/// everything ahead of the cursor, and re-visiting the item you are already on does nothing at all.
/// Without the second rule, clicking the selected sidebar row — which the app does on every
/// re-selection, including the ones it triggers itself — would stack duplicates until "back" walked
/// you through the same endpoint a dozen times.
nonisolated struct NavigationHistory<Item: Equatable>: Equatable {
    /// Enough to retrace a working session, small enough that the array never becomes a leak.
    static var capacity: Int { 50 }

    /// Where you are. `nil` until something has been visited.
    private(set) var current: Item?

    private var entries: [Item] = []
    /// Index into `entries`; `-1` while the history is empty.
    private var index: Int = -1

    init() {}

    var canGoBack: Bool { index > 0 }

    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    /// Records a move to `item`. A new visit truncates any forward entries — the standard rule.
    /// Visiting the item you are already on is a no-op, so re-selecting does not stack duplicates.
    mutating func visit(_ item: Item) {
        guard current != item else { return }

        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }

        entries.append(item)

        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }

        index = entries.count - 1
        refreshCurrent()
    }

    @discardableResult
    mutating func goBack() -> Item? {
        guard canGoBack else { return nil }
        index -= 1
        refreshCurrent()
        return current
    }

    @discardableResult
    mutating func goForward() -> Item? {
        guard canGoForward else { return nil }
        index += 1
        refreshCurrent()
        return current
    }

    private mutating func refreshCurrent() {
        current = entries.indices.contains(index) ? entries[index] : nil
    }
}

// MARK: - Preview

#Preview("Breadcrumb jump bar") {
    BreadcrumbJumpBar(
        crumbs: [
            .init(
                id: "group",
                title: "Checkout",
                systemImage: "folder",
                options: [
                    .init(title: "Checkout", isSelected: true),
                    .init(title: "Accounts"),
                ]
            ),
            .init(
                id: "endpoint",
                title: "POST /v1/orders",
                options: [
                    .init(title: "POST /v1/orders", isSelected: true),
                    .init(title: "GET /v1/orders/{id}"),
                ]
            ),
            .init(id: "scenario", title: "Happy path"),
        ],
        canGoBack: true,
        onSelectOption: { _, _ in }
    )
    .frame(width: 420)
    .background(DSColors.dominant)
}
