import SwiftUI

/// A panel that names the mode it is in, and lets you go back.
///
/// **The problem this solves is that the inspector changes identity under you.** Its mode is derived
/// from what you last clicked — a log row shows the request, an endpoint shows its scenarios,
/// nothing selected shows the project — and until now that derivation was invisible. The panel
/// simply became a different panel, with no label saying so and no way to return without
/// reproducing the selection that got you there.
///
/// So: the modes are named, the current one is marked, and clicking one is how you override the
/// derivation.
///
/// **A mode with nothing to show is disabled rather than hidden.** Hiding it would move the other
/// two, so the control a user is aiming at would shift as their selection changed — and a rail whose
/// items move is worse than one with a dimmed item in it.
public struct DSModeRail<Mode: Hashable>: View {
    public struct Item: Identifiable {
        public let id: Mode
        public let title: String
        /// `false` when this mode has nothing to show — drawn at `labelTertiary` and inert.
        public let isEnabled: Bool

        public init(id: Mode, title: String, isEnabled: Bool = true) {
            self.id = id
            self.title = title
            self.isEnabled = isEnabled
        }
    }

    private let items: [Item]
    private let selection: Mode
    private let identifier: String
    private let onSelect: (Mode) -> Void

    public init(
        items: [Item],
        selection: Mode,
        identifier: String,
        onSelect: @escaping (Mode) -> Void
    ) {
        self.items = items
        self.selection = selection
        self.identifier = identifier
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xs) {
            ForEach(items) { item in
                DSModeRailItem(
                    title: item.title,
                    isSelected: item.id == selection,
                    isEnabled: item.isEnabled,
                    identifier: "\(identifier).\(item.title.lowercased())",
                    action: { onSelect(item.id) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

private struct DSModeRailItem: View {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let identifier: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.xxs) {
                if isSelected {
                    // A dot as well as the fill and the weight, so "which mode am I in" survives
                    // greyscale and Differentiate Without Color.
                    Circle()
                        .fill(DSColors.accent)
                        .frame(width: 5, height: 5)
                }
                Text(title)
                    .font(isSelected ? DSTypography.controlLabel : DSTypography.controlLabelQuiet)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, DSSpacing.sm)
            .frame(height: 22)
            .background {
                RoundedRectangle(cornerRadius: DSCornerRadius.smPlus)
                    .fill(background)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 && isEnabled }
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help(isEnabled ? "Show \(title.lowercased())" : "\(title) has nothing to show")
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var foreground: Color {
        // `labelSecondary` for an unselected item, never tertiary: an inspector mode is a control's
        // own label, and 36% measures 2.48:1. Tertiary is reserved for the *disabled* case, where
        // being hard to read is the message.
        guard isEnabled else { return DSColors.labelTertiary }
        if isSelected { return DSColors.labelPrimary }
        return isHovered ? DSColors.labelPrimary : DSColors.labelSecondary
    }

    private var background: Color {
        // `labelPrimary @ 9%` measures 4.36:1 for `labelSecondary` text on it — under the floor — so
        // the selected item takes `labelPrimary` at full strength for its *text* and the fill only
        // has to separate the pill from the bar.
        if isSelected { return DSColors.labelPrimary.opacity(0.09) }
        return isHovered ? DSColors.accentSubtle : .clear
    }
}

/// The one-line answer to "why is this panel showing this?".
///
/// It sits directly under the mode rail and states the rule in words: *following the request log
/// selection*, *following the selected endpoint*, *no selection — showing project state*. That pair —
/// a rail that names the mode and a line that explains it — is the whole fix for a panel that used
/// to change identity silently.
///
/// Deliberately one line and deliberately quiet. The design's own mock draws a second, larger
/// explanatory card beneath it; two sentences of prose in a 320pt panel explaining that panel's own
/// behaviour is documentation shipped as chrome.
public struct DSProvenanceLine: View {
    private let text: String
    private let identifier: String

    public init(_ text: String, identifier: String) {
        self.text = text
        self.identifier = identifier
    }

    public var body: some View {
        Text(text)
            .font(DSTypography.metaSmall)
            .foregroundStyle(DSColors.labelSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSSpacing.mdPlus)
            .padding(.top, DSSpacing.smPlus)
            .padding(.bottom, DSSpacing.sm)
            .accessibilityIdentifier(identifier)
    }
}
