import SwiftUI

/// Panel navigation with content-sized icon-and-title buttons that fall back to icons together.
/// The accessory always keeps its space. Both presentations retain the same height, identities,
/// selection and keyboard behavior; resizing does not animate or truncate the labels.
public struct DSTabStrip: View {
    public struct Tab: Identifiable, Equatable, Sendable {
        public let id: String
        public var systemImage: String
        public var help: String
        public var badge: Int?
        /// Supply titles for every tab to enable adaptive labels. Untitled strips stay icon-only.
        public var title: String?

        public init(id: String, systemImage: String, help: String, badge: Int? = nil, title: String? = nil) {
            self.id = id
            self.systemImage = systemImage
            self.help = help
            self.badge = badge
            self.title = title
        }
    }

    private let tabs: [Tab]
    @Binding private var selection: String
    private let identifier: String
    private let accessory: AnyView?
    private let drawsChrome: Bool

    public init(tabs: [Tab], selection: Binding<String>, identifier: String, drawsChrome: Bool = true) {
        self.tabs = tabs
        self._selection = selection
        self.identifier = identifier
        self.accessory = nil
        self.drawsChrome = drawsChrome
    }

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
            ViewThatFits(in: .horizontal) {
                if !tabs.isEmpty, tabs.allSatisfy({ $0.title != nil }) {
                    tabButtons(showsTitles: true)
                }
                tabButtons(showsTitles: false)
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.leading, DSSpacing.xs)
        .padding(.trailing, drawsChrome ? DSSpacing.md : DSSpacing.xs)
        .padding(.vertical, DSSpacing.xxs)
        .frame(height: drawsChrome ? DSBarHeight.panelHeader : nil)
        .background(drawsChrome ? DSColors.secondary : Color.clear)
        .overlay(alignment: .bottom) {
            if drawsChrome {
                Rectangle()
                    .fill(DSColors.separator)
                    .frame(height: DSStroke.hairline)
            }
        }
        // Contain first, then identify the group, so its controls retain their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.tabstrip.\(identifier)")
    }

    private func tabButtons(showsTitles: Bool) -> some View {
        HStack(spacing: DSSpacing.xxs) {
            ForEach(tabs) { tab in
                TabButton(
                    tab: tab,
                    showsTitle: showsTitles,
                    isSelected: tab.id == selection,
                    identifier: "\(identifier).tab.\(tab.id)"
                ) { selection = tab.id }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private struct TabButton: View {
        let tab: DSTabStrip.Tab
        let showsTitle: Bool
        let isSelected: Bool
        let identifier: String
        let select: () -> Void

        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button(action: select) {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: DSGlyph.controlProminent, weight: .medium))
                        .frame(width: DSControlHeight.field)
                        .overlay(alignment: .topTrailing) { badge }
                    if showsTitle, let title = tab.title {
                        Text(title)
                            .font(DSTypography.label)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, showsTitle ? DSSpacing.md : DSSpacing.xs)
                .frame(height: DSControlHeight.navigation)
                .foregroundStyle(iconColor)
                .background(RoundedRectangle(cornerRadius: DSCornerRadius.sm).fill(selectionFill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: DSAnimation.micro), value: isHovered)
            .help(tab.help)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(tab.help)
            .accessibilityValue(badgeAnnouncement)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }

        // The dot does not consume width; the exact count remains available to VoiceOver.
        @ViewBuilder
        private var badge: some View {
            if (tab.badge ?? 0) > 0 {
                Circle()
                    .fill(DSColors.httpStatusColor(for: 404))
                    .frame(width: DSSpacing.sm, height: DSSpacing.sm)
                    .overlay(Circle().stroke(DSColors.secondary, lineWidth: DSStroke.seam))
                    .offset(x: DSSpacing.xxs, y: -DSSpacing.xxs)
                    .allowsHitTesting(false)
            }
        }

        private var selectionFill: Color {
            if isSelected { return DSColors.accent }
            return isHovered ? DSColors.accentSubtle : .clear
        }

        private var iconColor: Color {
            if isSelected { return .white }
            return isHovered ? DSColors.labelPrimary : DSColors.labelSecondary
        }

        private var badgeAnnouncement: String {
            guard let badge = tab.badge, badge > 0 else { return "" }
            return "\(badge)"
        }
    }
}
