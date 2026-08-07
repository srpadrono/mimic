import SwiftUI
import DesignSystem

/// Where the centre pane can go from here, injected by the composition root.
///
/// This is what the jump bar used to be. The bar drew a trail — `project ▸ group ▸ endpoint ▸
/// scenario` — where every segment past the first was a menu over its siblings, and that sideways
/// movement was the half worth keeping: switching to another endpoint in the same group without a
/// round trip through the sidebar. What was *not* worth keeping was the 24pt band it needed to draw
/// the trail in, which was the only thing stopping the window's four panel headers from starting at
/// the same y.
///
/// So the trail is gone and the moves live in the editor's own overflow menu, where the endpoint's
/// other actions already are. Two things follow from that:
///
/// - **The project crumb does not survive.** It carried no options — it was a label naming the open
///   project, and the toolbar already does that.
/// - **The scenario crumb does not survive here either.** Scenario switching stays available in the
///   inspector's Scenarios mode, and the redesign gives it a permanent home in the editor's own
///   title row (`DSScenarioControl`). Re-homing it into an overflow menu in between would be a
///   third place to look for one control.
///
/// Shaped as a value type rather than an environment object for the same reason
/// ``EndpointEditorActions`` is: the editors stay decoupled from `AppState`, and a section list is a
/// plain value a test can build.
struct CenterPaneNavigation {
    /// One lateral move.
    struct Option: Identifiable, Equatable {
        let id: UUID
        var title: String
        var isSelected: Bool

        init(id: UUID, title: String, isSelected: Bool = false) {
            self.id = id
            self.title = title
            self.isSelected = isSelected
        }
    }

    /// A group of lateral moves, rendered as one titled section of the overflow menu.
    struct JumpSection: Identifiable, Equatable {
        /// Stable per *level* — "group", "endpoint", "journey" — so the accessibility identifier
        /// holds steady while the titles underneath change. Same contract the crumb ids had.
        let id: String
        var title: String
        var options: [Option]

        init(id: String, title: String, options: [Option]) {
            self.id = id
            self.title = title
            self.options = options
        }
    }

    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var jumpSections: [JumpSection] = []
    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
    /// (section id, chosen option id)
    var onJump: (String, UUID) -> Void = { _, _ in }

    /// Sections with nothing to offer are dropped rather than drawn empty — a menu section
    /// containing one item that is already selected is a menu that does nothing when you use it.
    var usableSections: [JumpSection] {
        jumpSections.filter { $0.options.count > 1 }
    }
}

// MARK: - History controls

/// The back/forward pair, sized for a 30pt panel header.
///
/// Lifted from the jump bar with its geometry intact — 18pt frame, 10pt glyph, `sm` hover well —
/// because that geometry was chosen against the rest of the window's controls and none of those
/// moved. Two notes from its original home that are still load-bearing:
///
/// - The icon is a `Label` with the text styled away rather than a bare `Image`, so VoiceOver and
///   Voice Control still have something to say, and the 18pt frame plus `contentShape` gives it a
///   real hit target rather than the ~10pt the glyph would offer alone.
/// - Disabled is `labelTertiary` **alone**. Compounding it with `.opacity(0.4)` gave 14% effective
///   alpha — below AppKit's own ~25% `disabledControlTextColor`, where a control stops reading as
///   disabled and starts reading as a drawing glitch.
struct EditorHistoryControls: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let onBack: () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            EditorHistoryButton(
                systemImage: "chevron.left",
                label: "Go back",
                identifier: "editor.navigation.back",
                isEnabled: canGoBack,
                action: onBack
            )

            EditorHistoryButton(
                systemImage: "chevron.right",
                label: "Go forward",
                identifier: "editor.navigation.forward",
                isEnabled: canGoForward,
                action: onForward
            )
        }
    }
}

private struct EditorHistoryButton: View {
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
        guard isEnabled else { return DSColors.labelTertiary }
        return isHovered ? DSColors.labelPrimary : DSColors.labelSecondary
    }
}

// MARK: - Jump menu content

/// The lateral moves, as titled sections inside an editor's existing overflow menu.
///
/// A `Section` per level rather than a flat list, because "Accounts" and "GET /v1/orders" mean
/// different things and a flat menu of both reads as one list of unrelated nouns.
///
/// The current item carries a `checkmark` rather than a tint, so the choice you are on survives
/// Differentiate Without Color — the same reason the crumb menus drew one.
struct CenterPaneJumpSections: View {
    let navigation: CenterPaneNavigation

    var body: some View {
        ForEach(navigation.usableSections) { section in
            Section(section.title) {
                ForEach(section.options) { option in
                    Button {
                        navigation.onJump(section.id, option.id)
                    } label: {
                        if option.isSelected {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                    .accessibilityIdentifier("editor.jump.\(section.id).\(option.id.uuidString)")
                    .accessibilityLabel(option.isSelected ? "\(option.title), selected" : option.title)
                }
            }
        }
    }
}
