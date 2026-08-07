import SwiftUI

/// A filter field with an optional scope selector, sized to sit in a panel's chrome.
///
/// Modelled on Xcode's navigator filter bar, and pinned like it: this is a panel's own control, not
/// the first row of its content. The sidebar learned that distinction the hard way — its search
/// field used to scroll inside the list, so it left the screen exactly when the list got long
/// enough to need it.
///
/// The scope selector is what makes one field enough. Without it a panel grows a second filter for
/// "search paths" versus "search bodies"; with it the question of *what* is being matched lives in
/// the same 20pt row as the text being matched, and a restriction that is switched on announces
/// itself there instead of hiding behind a closed menu.
/// **Identifiers, as they actually arrive.** The container is tagged `ds.filterfield.<identifier>`,
/// and AppKit hands that same name to the text field and the scope menu inside it — pairing the
/// container with `.accessibilityElement(children: .contain)` does not stop that, because this wraps
/// a single control rather than a set of them. So a test queries `ds.filterfield.<identifier>` and
/// separates the two by element type: `app.textFields[…]` for the field, `app.menuButtons[…]` for the
/// scope. The `<identifier>.field` and `<identifier>.scope` names below are applied, but never win.
public struct DSFilterField: View {
    /// One thing the filter can be pointed at. The `id` is what the caller stores; the `title` is
    /// only ever shown.
    public struct Scope: Identifiable, Equatable, Sendable {
        public let id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    @Binding private var text: String
    @Binding private var scopeID: String
    private let scopes: [Scope]
    private let placeholder: String
    private let identifier: String

    public init(
        text: Binding<String>,
        scopeID: Binding<String>,
        scopes: [Scope],
        placeholder: String,
        identifier: String
    ) {
        self._text = text
        self._scopeID = scopeID
        self.scopes = scopes
        self.placeholder = placeholder
        self.identifier = identifier
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xs) {
            // Absent rather than disabled when there is nothing to choose between: a dead control
            // in a 20pt row is worse than no control, because it still costs width.
            if !scopes.isEmpty {
                ScopeMenu(scopes: scopes, scopeID: $scopeID, identifier: identifier)
            }

            // No magnifying glass. Xcode's filter bar has none, and here it would land immediately
            // beside the scope pill — two glyphs fighting over the same corner, one of which only
            // repeats what the placeholder already says.
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DSTypography.codeSmall)
                .accessibilityIdentifier("\(identifier).field")
                .accessibilityLabel(placeholder)

            if !text.isEmpty {
                DSClearButton(
                    text: $text,
                    identifier: "\(identifier).clear",
                    label: "Clear filter",
                    help: "Clear the filter"
                )
            }
        }
        // The well. A full capsule, not a 4pt rounded rectangle: at this height the rectangle read
        // as a text field that had wandered out of a form, while the capsule reads as one recessed
        // track with controls living inside it — which is the whole point, since the scope pill and
        // the clear button are inside it rather than beside it. Fill, hairline and padding are
        // unchanged, so the row keeps its height and the sidebar keeps its rhythm.
        .padding(.horizontal, DSSpacing.sm)
        // Pinned, not inferred. The doc above has always claimed a 20pt row, and every sibling
        // control states its own height — but this one never did, so its height was whatever the
        // scope `Menu` inside it happened to measure. The one control that promised to match its
        // neighbours was the only one not measuring itself.
        .frame(height: 20)
        .background {
            Capsule()
                .fill(DSColors.surfaceWell)
                .stroke(DSColors.border, lineWidth: 0.5)
        }
        // Paired deliberately: an identifier alone on a container overrides its descendants', and
        // `…field`, `…scope` and `…clear` would all vanish from the accessibility tree at once.
        .accessibilityIdentifier("ds.filterfield.\(identifier)")
        .accessibilityElement(children: .contain)
    }

    /// The scope pill.
    ///
    /// Wordless while unscoped — a filter glyph and a chevron — because the unrestricted case is the
    /// default, and spending a title on "no restriction is in force" takes the width away from the
    /// text being typed. A scope that *is* cutting results down says so: it shows its title and
    /// turns accent-coloured, because a filter silently hiding rows with no visible sign of it is
    /// the worse failure, and it is worth the width every time it happens.
    ///
    /// AppKit realizes a SwiftUI `Menu` as a menu button rather than a button, so a UI test looks
    /// for this under `menuButtons`/`popUpButtons`, not `buttons`.
    private struct ScopeMenu: View {
        let scopes: [DSFilterField.Scope]
        @Binding var scopeID: String
        let identifier: String

        @State private var isHovered = false

        var body: some View {
            Menu {
                ForEach(scopes) { scope in
                    Button(scope.title) { scopeID = scope.id }
                }
            } label: {
                HStack(spacing: DSSpacing.xxs) {
                    // The filter glyph, not a magnifier, and that is a decision rather than an
                    // oversight: this component narrows a list that is already on screen, and every
                    // string around it agrees — "Filter endpoints", "Clear filter", "Choose what the
                    // filter searches". The magnifier belongs to the request detail's "Find in body",
                    // which really is a search. See the type's note for why one would not fit here
                    // anyway: it would land immediately beside this pill, two glyphs in one corner.
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 9, weight: .medium))

                    if isScoped {
                        Text(title)
                            .font(DSTypography.caption)
                    }

                    // At rest this is the *only* thing saying the pill is a control, because the pill
                    // has no title until a scope is chosen. Without a visible mark it reads as
                    // decoration sitting where a search field's magnifier usually sits, and the scope
                    // is never discovered — which is what a look at the running sidebar found.
                    //
                    // `chevron.up.chevron.down`, not a lone `chevron.down`: this picks one of N values
                    // and shows the one in force, which is a pop-up. 8pt is the window's
                    // menu-indicator size and the floor below which the mark becomes a smudge.
                    //
                    // It takes the pill's own colour rather than dropping to `labelTertiary`. The
                    // breadcrumb jump bar — which held the same mark until it was deleted — could
                    // afford tertiary because a crumb's title carried the message and the chevron only
                    // annotated it. Here there is no title to annotate, so the mark is the message.
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(foreground)
                .padding(.horizontal, DSSpacing.xs)
                .padding(.vertical, 1)
                .background {
                    // Fill *and* hairline. The fill on its own was `secondary` sitting on the field's
                    // `tertiary` track: 3% apart in light mode, and inverted in dark, where
                    // `secondary` is the *darker* of the two — so the pill read as a deeper recess
                    // than the well it sits inside rather than as a control on top of it. No surface
                    // token is raised against `tertiary` in both appearances, which is precisely the
                    // case `DSButton`'s secondary variant states a hairline for: a control stays
                    // visible on any surface only when it does not borrow that surface's colour.
                    Capsule()
                        .fill(DSColors.secondary)
                        .stroke(DSColors.border, lineWidth: 0.5)
                }
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
            // `.button` + `.plain`, and this file is now the only holder of the pairing — the
            // breadcrumb jump bar's crumb menu wore it too and was deleted, so the reasoning is
            // restated here in full rather than left pointing at a file that no longer exists.
            //
            // **Why `.button` and not `.borderlessButton`.** A borderless *menu* is realised as an
            // `NSPopUpButton`, which draws its own indicator *before* the label and ignores
            // `.menuIndicator(.hidden)`. On the breadcrumb that put a stray chevron in front of every
            // clickable crumb and swallowed the compact one the label drew after the title. Any menu
            // whose label is a word you read wants `.button`; a menu whose label is a bare glyph — the
            // editors' `ellipsis` overflow — is the one case where `.borderlessButton` is correct,
            // because there the bordered style would only add a permanent well around the glyph.
            //
            // **Why `.plain` and not `.borderless`.** Apple's deprecation message for
            // `.menuStyle(.borderlessButton)` literally names the pair ("use `menuStyle(.button)` and
            // `buttonStyle(.borderless)`"). That recipe is right about the *menu* style and is the
            // wrong half to copy for a label that draws itself: the label above draws every pixel of
            // this control — its own foreground, its own capsule, its own chevron — and `.borderless`
            // supplies a system accent tint to content whose colour this pill sets and switches on
            // `isScoped`.
            //
            // What is *not* claimed: that the style was why a look at the running sidebar found this
            // pill rendering as a bare glyph. The fill below is a proven cause of that on its own, and
            // the two were not isolated from each other.
            .menuStyle(.button)
            .buttonStyle(.plain)
            // The chevron is drawn above; the system indicator would be a second one.
            .menuIndicator(.hidden)
            // Without this the menu stretches and takes the width off the text field.
            .fixedSize()
            .help("Choose what the filter searches")
            // The pill carries no text while unscoped, so the label and value are the entire reading
            // VoiceOver gets — the glyphs say nothing on their own.
            .accessibilityIdentifier("\(identifier).scope")
            .accessibilityLabel("Filter scope")
            .accessibilityValue(title)
        }

        /// Accent whenever a scope is in force, because a filter quietly hiding rows has to say so
        /// without being pointed at. Otherwise the same lift every other menu-shaped control in the
        /// window gives the pointer — `DSPanelHeaderButton`, the editors' more menu and the centre
        /// pane's history arrows all go `labelSecondary` → `labelPrimary`; this pill was the one that
        /// stayed inert.
        private var foreground: Color {
            if isScoped { return DSColors.accentText }
            return isHovered ? DSColors.labelPrimary : DSColors.labelSecondary
        }

        /// The scope on show: the one `scopeID` names, or the first as a fallback.
        ///
        /// A `scopeID` matching nothing — a restored preference pointing at a scope that has since
        /// been renamed — would otherwise leave the pill blank, and a blank pill reads as a
        /// rendering failure rather than a stale setting. Showing the first scope keeps the control
        /// legible; keeping `scopeID` valid is the caller's job.
        private var selection: DSFilterField.Scope? {
            scopes.first { $0.id == scopeID } ?? scopes.first
        }

        private var title: String {
            selection?.title ?? ""
        }

        /// Whether the filter is restricting anything. The first scope is the unrestricted one by
        /// convention — callers put their "Any" sentinel there — so anything after it is a cut the
        /// user has to be able to see. Read off ``selection`` rather than `scopeID` so the colour,
        /// the title and the fallback can never disagree about which scope is in force.
        private var isScoped: Bool {
            selection?.id != scopes.first?.id
        }
    }

}
