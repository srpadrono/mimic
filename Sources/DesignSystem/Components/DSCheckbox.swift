import SwiftUI

/// The table checkbox: a 14 pt box, accent with a white tick when on and a white dash when mixed,
/// an outline when off. It is drawn rather than native so it keeps the design's colour whether or
/// not its window is in front.
///
/// It draws the box only, with its label read by assistive technology, to which it stays a
/// checkbox. Space toggles it under keyboard navigation.
public struct DSCheckboxToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        DSCheckboxRow(configuration: configuration)
    }
}

public extension ToggleStyle where Self == DSCheckboxToggleStyle {
    /// The design-system checkbox. See ``DSCheckboxToggleStyle``.
    static var dsCheckbox: DSCheckboxToggleStyle { DSCheckboxToggleStyle() }
}

private struct DSCheckboxRow: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // The box alone: the table's checkboxes sit in a column with no title beside them. The
        // label still names the checkbox to assistive technology.
        DSCheckboxBox(mark: mark)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .focusable(isEnabled, interactions: .activate)
            .onKeyPress(.space) {
                toggle()
                return .handled
            }
            .opacity(isEnabled ? 1 : 0.4)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
                    .toggleStyle(.checkbox)
            }
    }

    private var mark: DSCheckboxBox.Mark {
        if configuration.isMixed { return .mixed }
        return configuration.isOn ? .on : .off
    }

    private func toggle() {
        guard isEnabled else { return }
        // A mixed box selects everything it stands for, as the system checkbox does.
        configuration.isOn = configuration.isMixed ? true : !configuration.isOn
    }
}

/// The box alone.
struct DSCheckboxBox: View {
    enum Mark { case off, on, mixed }

    static let size: CGFloat = 14
    static let radius: CGFloat = 4

    let mark: Mark

    var body: some View {
        ZStack {
            switch mark {
            case .off:
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(DSColors.labelTertiary, lineWidth: 1)
            case .on, .mixed:
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(DSColors.accent)
                Image(systemName: mark == .on ? "checkmark" : "minus")
                    .font(.system(size: DSGlyph.disclosure, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}
