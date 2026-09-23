import SwiftUI

/// A native macOS picker with the same label spacing and type as the design system's form fields.
public struct DSFormPicker<Selection: Hashable, Options: View>: View {
    private let title: String
    @Binding private var selection: Selection
    private let identifier: String
    private let options: Options

    public init(_ title: String, selection: Binding<Selection>, identifier: String,
                @ViewBuilder options: () -> Options) {
        self.title = title
        self._selection = selection
        self.identifier = identifier
        self.options = options()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(title)
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelSecondary)
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .font(DSTypography.body)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(title)
        }
    }
}
