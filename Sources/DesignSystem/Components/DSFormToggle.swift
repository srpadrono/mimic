import SwiftUI

/// A labelled switch for settings sheets, with the same type and row rhythm as form fields.
public struct DSFormToggle: View {
    private let title: String
    @Binding private var isOn: Bool
    private let identifier: String

    public init(_ title: String, isOn: Binding<Bool>, identifier: String) {
        self.title = title
        self._isOn = isOn
        self.identifier = identifier
    }

    public var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .font(DSTypography.body)
            .foregroundStyle(DSColors.labelPrimary)
            .tint(DSColors.accent)
            .frame(minHeight: DSControlHeight.prominent)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(title)
    }
}
