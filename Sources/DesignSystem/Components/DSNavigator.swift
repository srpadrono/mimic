import SwiftUI

/// Shared geometry for both navigator modes. List rows supply their own insets so native
/// selection, focus, and keyboard navigation remain owned by List.
public enum DSNavigatorMetrics {
    public static let rowHeight: CGFloat = 26
    public static let inset: CGFloat = 12
    public static let indentation: CGFloat = 16
    public static let iconSlot: CGFloat = 16
    public static let methodWidth: CGFloat = 48
    public static let metadataWidth: CGFloat = 88
    public static let headerHeight: CGFloat = 38
    public static let footerHeight: CGFloat = 42
    public static let minimumWidth: CGFloat = 240
    public static let idealWidth: CGFloat = 260
    public static let maximumWidth: CGFloat = 360
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

/// A native segmented picker with one separate creation action.
public struct DSNavigatorHeader<Action: View>: View {
    private let modes: [DSNavigatorMode]
    @Binding private var selection: String
    private let action: Action

    public init(modes: [DSNavigatorMode], selection: Binding<String>, @ViewBuilder action: () -> Action) {
        self.modes = modes
        self._selection = selection
        self.action = action()
    }

    public var body: some View {
        HStack(spacing: DSSpacing.smPlus) {
            Picker("Navigator", selection: $selection) {
                ForEach(modes) { mode in
                    Text(mode.title)
                        .tag(mode.id)
                        .accessibilityIdentifier("navigator.tab.\(mode.id)")
                        .accessibilityLabel(mode.help)
                        .help(mode.help)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityIdentifier("navigator.mode")
            .accessibilityLabel("Navigator")

            Spacer(minLength: 0)
            action
                .frame(width: DSControlHeight.field, height: DSControlHeight.field)
        }
        .padding(.horizontal, DSNavigatorMetrics.inset)
        .frame(maxWidth: .infinity)
        .frame(height: DSNavigatorMetrics.headerHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("navigator.header")
    }
}

/// Filtering has one stable home below either list, including empty and no-match states.
public struct DSNavigatorFooter<Status: View>: View {
    @Binding private var text: String
    @Binding private var scopeID: String
    private let scopes: [DSFilterField.Scope]
    private let placeholder: String
    private let identifier: String
    private let status: Status

    public init(
        text: Binding<String>, scopeID: Binding<String>, scopes: [DSFilterField.Scope],
        placeholder: String, identifier: String, @ViewBuilder status: () -> Status
    ) {
        self._text = text
        self._scopeID = scopeID
        self.scopes = scopes
        self.placeholder = placeholder
        self.identifier = identifier
        self.status = status()
    }

    public var body: some View {
        HStack(spacing: DSSpacing.smPlus) {
            DSFilterField(
                text: $text, scopeID: $scopeID, scopes: scopes,
                placeholder: placeholder, identifier: identifier
            )
            status.frame(width: DSControlHeight.field, height: DSControlHeight.field)
        }
        .padding(.horizontal, DSNavigatorMetrics.inset)
        .frame(height: DSNavigatorMetrics.footerHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(DSColors.separator).frame(height: DSStroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("navigator.footer")
    }
}

public extension View {
    func dsNavigatorRow(indented: Bool = false) -> some View {
        self
            .frame(height: DSNavigatorMetrics.rowHeight)
            .padding(.leading, indented ? DSNavigatorMetrics.indentation : 0)
            .contentShape(Rectangle())
            .listRowInsets(EdgeInsets(
                // Native outline cells supply an additional eight-point content inset.
                top: 0, leading: DSNavigatorMetrics.inset - DSSpacing.smPlus,
                bottom: 0, trailing: DSNavigatorMetrics.inset - DSSpacing.smPlus
            ))
            .listRowSeparator(.hidden)
    }

    func dsNavigatorList() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, DSNavigatorMetrics.rowHeight)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .contentMargins(.vertical, DSSpacing.xs, for: .scrollContent)
    }
}
