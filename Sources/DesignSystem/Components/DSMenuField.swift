import SwiftUI

/// A choice drawn as a field: the chosen title in the field's fill and hairline, with one quiet
/// chevron at its trailing edge, as the design draws its menus inside forms.
///
/// A menu-style `Picker` draws AppKit's bordered pop-up button, whose own bezel and chevrons sit on
/// top of the field the design asks for. This is a `Menu` whose label is the field; the open menu
/// is an inline picker, so the chosen option keeps its checkmark.
public struct DSMenuField<Value: Hashable, Label: View>: View {
    /// The trailing glyph: up and down for a list of peers, down for a menu of shortcuts.
    public enum Indicator {
        case upDown
        case down

        var systemImage: String {
            switch self {
            case .upDown: "chevron.up.chevron.down"
            case .down: "chevron.down"
            }
        }
    }

    private let title: String
    @Binding private var selection: Value
    private let options: [DSMenuOption<Value>]
    private let indicator: Indicator
    private let height: CGFloat
    private let identifier: String
    private let label: (Value) -> Label

    @Environment(\.isEnabled) private var isEnabled

    /// `title` names the choice for accessibility; `label` draws the chosen value inside the field.
    public init(
        _ title: String,
        selection: Binding<Value>,
        options: [DSMenuOption<Value>],
        indicator: Indicator = .upDown,
        height: CGFloat = DSControlHeight.regular,
        identifier: String,
        @ViewBuilder label: @escaping (Value) -> Label
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.indicator = indicator
        self.height = height
        self.identifier = identifier
        self.label = label
    }

    public var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: DSSpacing.sm) {
                label(selection)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: indicator.systemImage)
                    .font(.system(size: DSGlyph.minimum, weight: .semibold))
                    .foregroundStyle(DSColors.labelTertiary)
                    .accessibilityHidden(true)
            }
            .dsFieldChrome(height: height, isFocused: false)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        // `.plain` keeps the field as drawn; the system indicator would be a second chevron.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityValue(selectedTitle)
    }

    private var selectedTitle: String {
        options.first { $0.value == selection }?.title ?? ""
    }
}

public extension DSMenuField where Label == DSMenuFieldTitle {
    /// The chosen option's title, in the field's 12pt text.
    init(
        _ title: String,
        selection: Binding<Value>,
        options: [DSMenuOption<Value>],
        indicator: Indicator = .upDown,
        height: CGFloat = DSControlHeight.regular,
        identifier: String
    ) {
        self.init(title, selection: selection, options: options, indicator: indicator, height: height,
                  identifier: identifier) { value in
            DSMenuFieldTitle(options.first { $0.value == value }?.title ?? "")
        }
    }
}

/// The text a ``DSMenuField`` shows for its chosen option.
public struct DSMenuFieldTitle: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(DSTypography.callout)
            .foregroundStyle(DSColors.labelPrimary)
    }
}

/// One choice a ``DSMenuField`` offers.
nonisolated public struct DSMenuOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String

    public var id: Value { value }

    public init(_ title: String, value: Value) {
        self.title = title
        self.value = value
    }
}
