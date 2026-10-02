import SwiftUI

/// Shared geometry for both navigator modes. List rows supply their own insets so native
/// selection, focus, and keyboard navigation remain owned by List.
public enum DSNavigatorMetrics {
    public static let rowHeight = DSRowHeight.list
    public static let groupHeaderHeight: CGFloat = 24
    /// The gap between neighbouring rows and headings, so rounded selections never touch.
    public static let rowGap = DSSpacing.xxs
    /// From one row's top to the next one's: the row and its share of the gaps either side.
    public static let rowPitch = rowHeight + rowGap
    /// The sidebar's own inset; rows sit 8pt in so their rounded selection clears the glass edge.
    public static let inset = DSSpacing.md
    /// What a row adds to the inset the sidebar list already gives its cells. The list draws a
    /// row's content 16pt in from the panel edge, which is where the design puts it.
    public static let rowInset: CGFloat = 0
    /// How far the sidebar list draws its first row below its own top edge.
    static let listTopInset: CGFloat = 8
    /// The mode switch's space below it: the design's 10pt to the first heading, less what the
    /// list and the first heading's half gap already add.
    static let headerBottomPadding = 10 - listTopInset - rowGap / 2
    public static let indentation = DSSpacing.lg
    public static let iconSlot = DSSpacing.lg
    public static let footerHeight = DSBarHeight.footer
    public static let minimumWidth = DSLayout.sidebarMinimumWidth
    public static let idealWidth = DSLayout.sidebarWidth
    public static let maximumWidth = DSLayout.sidebarMaximumWidth

    static let rowInsets = EdgeInsets(top: rowGap / 2, leading: rowInset, bottom: rowGap / 2, trailing: rowInset)
}

public struct DSNavigatorMode: Identifiable {
    public let id: String
    public let title: String
    public let help: String

    public init(id: String, title: String, help: String) {
        self.id = id
        self.title = title
        self.help = help
    }
}

/// The navigator's mode switch: one full-width segmented control under the window controls.
public struct DSNavigatorHeader: View {
    private let modes: [DSNavigatorMode]
    @Binding private var selection: String

    public init(modes: [DSNavigatorMode], selection: Binding<String>) {
        self.modes = modes
        self._selection = selection
    }

    public var body: some View {
        DSSegmentedControl(
            "Navigator",
            segments: modes.map {
                .init($0.title, value: $0.id, help: $0.help, identifier: "navigator.tab.\($0.id)")
            },
            selection: $selection,
            fillsWidth: true,
            identifier: "navigator.mode"
        )
        .padding(.horizontal, DSNavigatorMetrics.inset)
        .padding(.bottom, DSNavigatorMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("navigator.header")
    }
}

/// Filtering and adding share one bar below either list, including empty and no-match states.
public struct DSNavigatorFooter<Accessory: View>: View {
    @Binding private var text: String
    @Binding private var scopeID: String
    private let scopes: [DSFilterField.Scope]
    private let placeholder: String
    private let label: String?
    private let identifier: String
    private let focusRequest: Int
    private let accessory: Accessory

    public init(
        text: Binding<String>, scopeID: Binding<String>, scopes: [DSFilterField.Scope],
        placeholder: String, label: String? = nil, identifier: String, focusRequest: Int = 0,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self._text = text
        self._scopeID = scopeID
        self.scopes = scopes
        self.placeholder = placeholder
        self.label = label
        self.identifier = identifier
        self.focusRequest = focusRequest
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: DSSpacing.sm) {
            DSFilterField(
                text: $text, scopeID: $scopeID, scopes: scopes,
                placeholder: placeholder, label: label, identifier: identifier, focusRequest: focusRequest
            )
            accessory
        }
        .padding(.horizontal, 10)
        .frame(height: DSNavigatorMetrics.footerHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(DSColors.separator).frame(height: DSStroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("navigator.footer")
    }
}

public extension View {
    /// A 28pt navigator row with half the row gap above and below it. The list draws the rounded
    /// selection; the row supplies its insets.
    func dsNavigatorRow(indented: Bool = false) -> some View {
        self
            .frame(height: DSNavigatorMetrics.rowHeight)
            .padding(.leading, indented ? DSNavigatorMetrics.indentation : 0)
            .contentShape(Rectangle())
            .listRowInsets(DSNavigatorMetrics.rowInsets)
            .listRowSeparator(.hidden)
    }

    /// A sidebar-style list: rounded native selection, no background, so the glass shows through.
    func dsNavigatorList() -> some View {
        self
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // The sidebar style sizes rows from the system's sidebar row size, not from the rows:
            // at the default size macOS 26 draws a 32pt row around a 28pt one. The smallest size
            // leaves the height to `defaultMinListRowHeight` below, so rows are the design's 28pt
            // whatever the user's "Sidebar icon size". Row fonts are set explicitly, so the size
            // changes nothing else.
            .environment(\.sidebarRowSize, .small)
            .environment(\.defaultMinListRowHeight, DSNavigatorMetrics.rowHeight)
            // Nothing on top: the list's own top inset already clears the mode switch.
            .contentMargins(.top, 0, for: .scrollContent)
            .contentMargins(.bottom, DSSpacing.xxs, for: .scrollContent)
    }
}

/// A group heading: disclosure chevron, 11pt semibold name, and a trailing count.
///
/// `.onHover` draws the name alone, as the journeys design does, and brings in a trailing chevron
/// while the pointer is over the heading, or while the group is collapsed, the way the Finder's
/// sidebar sections do. The heading toggles on a click either way.
public struct DSNavigatorGroup: View {
    public enum Disclosure {
        /// A leading chevron and a trailing count, always.
        case always
        /// The name alone at rest; a trailing chevron on hover or while collapsed.
        case onHover
    }

    public let name: String
    public let count: Int
    public let itemName: String
    public let isCollapsed: Bool
    public let identifier: String
    public let disclosure: Disclosure
    public let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    public init(name: String, count: Int, itemName: String, isCollapsed: Bool,
                identifier: String, disclosure: Disclosure = .always, toggle: @escaping () -> Void) {
        self.name = name
        self.count = count
        self.itemName = itemName
        self.isCollapsed = isCollapsed
        self.identifier = identifier
        self.disclosure = disclosure
        self.toggle = toggle
    }

    public var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                if disclosure == .always {
                    chevron
                }
                Text(name)
                    .font(DSTypography.captionSemibold)
                    .lineLimit(1)
                Spacer(minLength: DSSpacing.sm)
                switch disclosure {
                case .always:
                    Text("\(count)")
                        .font(DSTypography.caption.weight(.medium))
                        .monospacedDigit()
                case .onHover:
                    chevron
                        .opacity(isHovered || isCollapsed ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: DSAnimation.fast), value: isHovered)
                }
            }
            .foregroundStyle(DSColors.labelTertiary)
            .frame(height: DSNavigatorMetrics.groupHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .listRowInsets(DSNavigatorMetrics.rowInsets)
        .listRowSeparator(.hidden)
        .selectionDisabled()
        .help(name)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(isCollapsed ? "Expand" : "Collapse") \(name)")
        .accessibilityValue("\(count) \(itemName)")
        .accessibilityAddTraits(.isHeader)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: DSGlyph.disclosure - 1, weight: .semibold))
            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
            .animation(reduceMotion ? nil : .easeOut(duration: DSAnimation.fast), value: isCollapsed)
            .frame(width: 10)
    }
}
