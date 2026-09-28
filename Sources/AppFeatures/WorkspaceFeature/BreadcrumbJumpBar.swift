import SwiftUI
import Domain
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
/// - **28pt, not 36.** This sits *inside* the editor rather than above a panel. Matching the panel
///   header height would make it read as a fourth panel header and put two same-weight bars in a row
///   at the top of the window. Secondary chrome should look secondary — but it still has to be
///   readable, and the earlier 24pt bar was too short for the current 13pt labels.
/// - **Secondary is not disabled.** The whole bar once rendered at caption weight in the secondary
///   label colour, which read as greyed-out chrome. Crumbs are 13pt; the trailing crumb — where you
///   actually are — takes the primary label colour at medium weight, as Xcode's does.
/// - **A crumb with nowhere to go is not a control.** Zero options renders as plain text — no hover
///   response, no menu indicator — because a button that does nothing when clicked is worse than a
///   label. A crumb that *does* have options says so before you hover, with the same
///   `chevron.up.chevron.down` Xcode puts on its jump-bar segments.
/// - **The separators are punctuation.** The chevrons between crumbs are 8pt, tertiary, and hidden
///   from VoiceOver: they are the `▸` in the path, not something you can press.
/// - **The bar never widens the window.** At narrow centre widths, parent locations move into a
///   menu so the current endpoint and scenario remain readable without losing sideways navigation.
/// The one bar under the toolbar: where you are, as a trail of menus, with the autosave state at the
/// end. Back and forward live in the toolbar.
struct BreadcrumbJumpBar: View {
    @State private var isEarlierHovered = false
    static var height: CGFloat { DSBarHeight.jumpBar }

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
    let onSelectOption: (String, UUID) -> Void
    let autosaveStatus: AutosaveStatus

    init(
        crumbs: [Crumb],
        autosaveStatus: AutosaveStatus = .idle,
        onSelectOption: @escaping (String, UUID) -> Void
    ) {
        self.crumbs = crumbs
        self.autosaveStatus = autosaveStatus
        self.onSelectOption = onSelectOption
    }

    var body: some View {
        GeometryReader { geometry in
            barContent(compact: geometry.size.width < 440 && crumbs.count > 2)
        }
        .frame(height: Self.height)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("breadcrumb")
    }

    private func barContent(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if compact {
                earlierLocationsMenu
                BreadcrumbSeparator()
            }
            ForEach(Array(crumbs.enumerated()).filter { !compact || $0.offset >= crumbs.count - 2 }, id: \.element.id) { pair in
                if pair.offset > (compact ? crumbs.count - 2 : 0) {
                    BreadcrumbSeparator()
                }
                BreadcrumbCrumbView(
                    crumb: pair.element,
                    isLast: pair.offset == crumbs.count - 1,
                    onSelect: { optionID in onSelectOption(pair.element.id, optionID) }
                )
                .layoutPriority(pair.offset == crumbs.count - 1 ? 1 : 0)
            }
            Spacer(minLength: DSSpacing.sm)
            AutosaveStatusIndicator(status: autosaveStatus)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
    }

    private var earlierLocationsMenu: some View {
        Menu {
            ForEach(crumbs.dropLast(2)) { crumb in
                if !crumb.options.isEmpty {
                    Menu(crumb.title) {
                        Options(crumb: crumb) { onSelectOption(crumb.id, $0) }
                    }
                } else {
                    Text(crumb.title)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(DSTypography.callout)
                .foregroundStyle(isEarlierHovered ? DSColors.labelPrimary : DSColors.labelSecondary)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: DSCornerRadius.field, style: .continuous)
                        .fill(isEarlierHovered ? DSColors.hover : Color.clear)
                }
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { isEarlierHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.fast), value: isEarlierHovered)
        .help("Earlier locations")
        .accessibilityIdentifier("breadcrumb.earlierLocations")
        .accessibilityLabel("Earlier locations")
    }

    /// Shared by compact and expanded menus so the active location is a native selection in both.
    struct Options: View {
        let crumb: Crumb
        let onSelect: (UUID) -> Void

        var body: some View {
            Picker(crumb.title, selection: Binding<UUID?>(
                get: { crumb.options.first(where: \.isSelected)?.id },
                set: { if let id = $0 { onSelect(id) } }
            )) {
                ForEach(crumb.options) { option in
                    Text(option.title)
                        .tag(Optional(option.id))
                        .accessibilityIdentifier("breadcrumb.option.\(option.id.uuidString)")
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
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
                BreadcrumbJumpBar.Options(crumb: crumb, onSelect: onSelect)
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
            .animation(.easeOut(duration: DSAnimation.fast), value: isHovered)
            .help(crumb.title)
            .accessibilityIdentifier("breadcrumb.crumb.\(crumb.id)")
            .accessibilityLabel(crumb.title)
        }
    }

    private var restingColor: Color {
        isLast ? DSColors.labelPrimary : DSColors.labelSecondary
    }

    private func content(color: Color) -> some View {
        HStack(spacing: 4) {
            Text(crumb.title)
                .font(isLast ? DSTypography.calloutMedium : DSTypography.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            if isLast, crumb.options.isEmpty == false {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: DSGlyph.disclosure - 1, weight: .semibold))
                    .foregroundStyle(DSColors.labelTertiary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 3)
        .frame(height: 22)
        .contentShape(.rect)
    }
}


private struct BreadcrumbSeparator: View {
    var body: some View {
        Image(systemName: "chevron.right")
            // `indicator` — a mark that annotates something else and never speaks on its own, which
            // is exactly what punctuation between two crumbs is.
            .font(.system(size: DSGlyph.disclosure - 1, weight: .semibold))
            .foregroundStyle(DSColors.labelTertiary)
            .accessibilityHidden(true)
    }
}

// MARK: - History controls

/// A back or forward arrow, sized for the 28pt bar.
///
/// The icon is a `Label` with the text styled away rather than a bare `Image`, so VoiceOver and Voice
/// Control still have something to say, and the 18pt frame plus `contentShape` gives it a hit target
/// rather than the ~10pt the glyph would offer on its own.
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

    func canGoBack(where isValid: (Item) -> Bool) -> Bool {
        previousIndex(where: isValid) != nil
    }

    func canGoForward(where isValid: (Item) -> Bool) -> Bool {
        nextIndex(where: isValid) != nil
    }

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
        goBack(where: { _ in true })
    }

    @discardableResult
    mutating func goBack(where isValid: (Item) -> Bool) -> Item? {
        guard let previous = previousIndex(where: isValid) else { return nil }
        index = previous
        refreshCurrent()
        return current
    }

    @discardableResult
    mutating func goForward() -> Item? {
        goForward(where: { _ in true })
    }

    @discardableResult
    mutating func goForward(where isValid: (Item) -> Bool) -> Item? {
        guard let next = nextIndex(where: isValid) else { return nil }
        index = next
        refreshCurrent()
        return current
    }

    private func previousIndex(where isValid: (Item) -> Bool) -> Int? {
        guard index > 0 else { return nil }
        return entries[..<index].lastIndex(where: isValid)
    }

    private func nextIndex(where isValid: (Item) -> Bool) -> Int? {
        guard index >= 0, index < entries.count - 1 else { return nil }
        return entries[(index + 1)...].firstIndex(where: isValid)
    }

    private mutating func refreshCurrent() {
        current = entries.indices.contains(index) ? entries[index] : nil
    }
}

// MARK: - Preview

#Preview("Breadcrumb jump bar") {
    BreadcrumbJumpBar(
        crumbs: [
            .init(id: "group", title: "Checkout",
                  options: [.init(title: "Checkout", isSelected: true), .init(title: "Accounts")]),
            .init(id: "endpoint", title: "POST /v1/orders",
                  options: [.init(title: "POST /v1/orders", isSelected: true), .init(title: "GET /v1/orders/{id}")]),
            .init(id: "scenario", title: "Happy path",
                  options: [.init(title: "Happy path", isSelected: true), .init(title: "Declined")]),
        ],
        autosaveStatus: .saved,
        onSelectOption: { _, _ in }
    )
    .frame(width: 520)
    .background(DSColors.content)
}
