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
/// **`.menuStyle(.borderlessButton)`, deprecated and still here — but no longer for the reason it
/// was.** The app's other two hand-styled menus take `.menuStyle(.button)`:
/// `DSFilterField.ScopeMenu` and `BreadcrumbJumpBar`'s crumbs both do, and Apple's deprecation
/// message names `menuStyle(.button)` with `buttonStyle(.borderless)` as the replacement. This one
/// stayed behind because the menu style decides the AppKit element type, and
/// `MimicUITests/JourneyUITests.swift` separated two *identically-labelled* controls — the
/// navigator's "+" and the journeys empty state's call to action — by element type alone: changing
/// the style would have silently repointed that query at the other control. **That is fixed, and it
/// was fixed at the labels rather than here.** The menu is now "Choose how to add a journey" and the
/// empty state's button "Add journey", which is two names for two different actions and is what the
/// suite should have been separating them by all along. `.buttonStyle(.plain)` *is* shared with the
/// other two, and for the reason they give: the label below states its own foreground and switches
/// it on hover, so `.borderless` would put a system accent tint back over a colour this component
/// sets.
///
/// **What is left to answer before the style moves is about the pointer, not the tree.**
/// `DSPanelHeaderButton` — the button this menu is shaped to match — is built as though a `.plain`
/// button's hit target were its label and nothing more: its `DSControlHeight.field` frame, its hover
/// well and a `.contentShape(Rectangle())` all sit *inside* the `Button`'s label, under a note
/// saying bare `Image`s in `.plain` buttons "gave a ~11pt hit target". This component cannot copy
/// that construction — `EndpointEditorView.moreMenu` records that a frame inside a `Menu`'s label
/// fights the control the menu builds — so the frame and the well below are applied *outside* the
/// `Menu`, which holds only while the menu style fills what it is offered. Whether a
/// `.button`-styled `Menu` still fills those 22 points, or centres a 13pt glyph inside a well that
/// lights up across the whole square, is not decidable by reading; and no XCUITest in this
/// repository drives either of the two menus that already take `.button`, so the suite has never
/// answered it either. Move this with a running window in front of you, and run the UI suite.
///
/// A paragraph here once asserted the opposite: that the component took `.button`, in a doc comment
/// attached to a body that takes `.borderlessButton`. A comment that contradicts its own code is
/// exactly how a "modernisation" that silently rewrites what a UI query resolves to gets made.
///
/// **AppKit realizes this as a `MenuButton`.** A UI test reaches it through `app.menuButtons[…]`,
/// never `app.buttons[…]` — and, inside a container that flattens its children's identifiers, by
/// *label*. `JourneyUITests` still starts there, but the type is a locator now rather than the thing
/// telling two controls apart: with the labels distinct it falls back to a label match across every
/// element type, so the query answers the same before and after the style moves.
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
    ///     site needs the spoken name to differ from the tooltip: the navigator's "+" is tooltipped
    ///     "Add a journey" and labelled "Choose how to add a journey", because it opens a chooser
    ///     while the journeys empty state's button — "Add journey" — creates one outright. Two
    ///     controls doing different things must not answer to the same name; they did, and the UI
    ///     suite was left telling them apart by AppKit element type.
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
        // The element-type argument that used to be written here is gone, and so is the defect
        // behind it: the navigator's "+" and the journeys empty state's button no longer share a
        // label, so `JourneyUITests` no longer separates them by what AppKit realizes each as, and
        // this modifier no longer decides which control a UI query finds.
        //
        // What holds it back now is the hit target — the frame and the well below sit outside this
        // `Menu` rather than inside a `Button`'s label the way `DSPanelHeaderButton` puts them, and
        // nothing here can tell you what a `.button`-styled `Menu` does with them. The type's note
        // above says what to check in a running window before this line becomes `.menuStyle(.button)`.
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
