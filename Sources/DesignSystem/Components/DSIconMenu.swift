import SwiftUI

/// A 22pt icon menu for panel chrome, shared by the journey navigator and endpoint editor.
///
/// The frame and content shape belong inside the menu label. With `.menuStyle(.button)`, putting
/// them only around `Menu` leaves AppKit with an 11–13pt actionable element. Focused macOS UI tests
/// click beyond the glyph at both horizontal edges and verify the menu actions and AX titles.
/// The outer frame and hover well keep the visible control aligned with `DSPanelHeaderButton`.
public struct DSIconMenu<Content: View>: View {
    private let systemImage: String
    private let help: String
    private let label: String
    private let identifier: String
    private let content: Content

    @State private var isHovered = false

    /// `label` names the chooser in accessibility and may differ from its hover `help` text.
    /// The journey chooser uses a name distinct from the empty state's direct add button.
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
            // Keep a semantic title for AppKit; an Image-only menu exposed an empty AX title on CI.
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .accessibilityLabel(label)
                .font(.system(size: DSGlyph.controlProminent, weight: .medium))
                // `labelSecondary` at rest, never `labelTertiary`: at 36% alpha an icon-only control
                // is one you have to already know about to find. `DSPanelHeaderButton` records the
                // same correction for the buttons this sits beside.
                .foregroundStyle(isHovered ? DSColors.labelPrimary : DSColors.labelSecondary)
                .frame(width: DSControlHeight.field, height: DSControlHeight.field)
                .contentShape(Rectangle())
        }
        // `.plain` keeps the explicit glyph colour; the label's frame supplies the hit target.
        .menuStyle(.button)
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
