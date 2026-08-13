import SwiftUI

/// A compact icon menu sized to sit in a panel's chrome — `DSPanelHeaderButton`'s shape, for the
/// cases where the control has to be a `Menu` rather than a `Button`.
///
/// The two existed as one seventeen-line block copied into two modules' worth of call sites: the
/// navigator's "+" on the Journeys tab (`WorkspaceView.addJourneyMenu`) and the endpoint editor's
/// more menu (`EndpointEditorView.moreMenu`). Same 22pt target, same `DSCornerRadius.sm` well, same
/// `accentSubtle` hover fill, same `DSAnimation.micro` cross-fade, same `labelSecondary` →
/// `labelPrimary` lift — each written out by hand, and each carrying a comment saying it deliberately
/// matched the other. That is the coupling `DSControlHeight` was extracted to stop: a promise held in
/// prose across a module boundary, verified by nobody.
///
/// **It is not `DSPanelHeaderButton` with a menu bolted on.** That type is a `Button`, and a `Menu`
/// cannot be one — a `Button` opens nothing, and wrapping a `Menu` inside one gives AppKit two
/// controls stacked on the same 22 points. The geometry is shared through the ladder instead, which
/// is the only part the two need to agree on.
///
/// **`.menuStyle(.borderlessButton)`, deprecated and kept on purpose — the reason is at the
/// modifier.** The app's other two hand-styled menus take `.menuStyle(.button)`:
/// `DSFilterField.ScopeMenu` and `BreadcrumbJumpBar`'s crumbs both do, and Apple's deprecation
/// message names `menuStyle(.button)` with `buttonStyle(.borderless)` as the replacement. This one
/// does not follow them, because the menu style is what decides the AppKit element type and
/// `MimicUITests/JourneyUITests.swift` separates two identically-labelled controls by element type
/// alone. `.buttonStyle(.plain)` *is* shared with those two, and for the reason they give: the label
/// below states its own foreground and switches it on hover, so `.borderless` would put a system
/// accent tint back over a colour this component sets.
///
/// The way out is to stop making element type load-bearing. This menu does set an
/// `.accessibilityLabel` below; what it does not have is a *distinct* one — `JourneysNavigatorPage`
/// records both the navigator's menu and the journeys empty state's button reporting "Add journey" —
/// so the suite has nothing left to separate them by. Give the two different labels and the style
/// stops carrying weight it was never meant to. That change has to run the XCUITest suite, which is
/// why it is not this one.
///
/// This paragraph used to assert the opposite: that the component took `.button`, in a doc comment
/// attached to a body that takes `.borderlessButton`. A comment that contradicts its own code is
/// exactly how a "modernisation" that silently rewrites what a UI query resolves to gets made.
///
/// **AppKit realizes this as a `MenuButton`.** A UI test reaches it through `app.menuButtons[…]`,
/// never `app.buttons[…]` — and, inside a container that flattens its children's identifiers, by
/// *label*. `JourneyUITests` matches the navigator's "+" on both at once, because the journeys empty
/// state carries the same words on a plain `Button`.
public struct DSIconMenu<Content: View>: View {
    private let systemImage: String
    private let help: String
    private let label: String
    private let identifier: String
    private let content: Content

    @State private var isHovered = false

    /// - Parameters:
    ///   - systemImage: The glyph. Drawn at ``DSGlyph/controlProminent`` — an icon-only control has
    ///     no title to carry the meaning, which is what puts it at the top of the ladder.
    ///   - help: The pointer tooltip.
    ///   - label: What VoiceOver reads, and what a UI test matches on when the enclosing container
    ///     has flattened the identifier. Defaults to `help`, and is split from it only where a call
    ///     site already has two strings: the navigator's "+" is tooltipped "Add a journey" and
    ///     labelled "Add journey", which is the string `JourneyUITests` knows it by.
    ///   - identifier: Applied, but do not assume it survives — see the type's note.
    ///   - content: The menu's items.
    public init(
        systemImage: String,
        help: String,
        label: String? = nil,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.systemImage = systemImage
        self.help = help
        self.label = label ?? help
        self.identifier = identifier
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: DSGlyph.controlProminent, weight: .medium))
                // `labelSecondary` at rest, never `labelTertiary`: at 36% alpha an icon-only control
                // is one you have to already know about to find. `DSPanelHeaderButton` records the
                // same correction for the buttons this sits beside.
                .foregroundStyle(isHovered ? DSColors.labelPrimary : DSColors.labelSecondary)
        }
        // `.borderlessButton` even though it is deprecated, and this is not an oversight.
        //
        // A `Menu` with this style is realized by AppKit as an `NSPopUpButton`, which XCUITest sees
        // as a `MenuButton`; `.button` is a push button that presents a menu, and is seen as a
        // `Button`. `MimicUITests/JourneyUITests.swift` separates the navigator's "Add journey" menu
        // from the empty state's identically-labelled "Add journey" *button* by element type alone —
        // its page object says so at length, because the identifier is no help (`DSTabStrip` flattens
        // its children's) and the label is shared. Modernising the style here silently rewrites what
        // that query resolves to, in a suite this component's own commit did not touch.
        //
        // The deeper fragility is the test's, not this component's: two controls that differ only by
        // AppKit realization are one framework change away from swapping. Giving the menu its own
        // accessibility label is the fix, and it belongs in a change that can run the UI suite.
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        // The label above draws the whole control; the system indicator would be a second glyph in a
        // 22pt box that already holds one.
        .menuIndicator(.hidden)
        .frame(width: DSControlHeight.field, height: DSControlHeight.field)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                .fill(isHovered ? DSColors.accentSubtle : Color.clear)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }
}
