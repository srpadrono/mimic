import SwiftUI

/// A native pop-up menu with the design system's form label. In sheets the label sits in the
/// right-aligned column beside it; in narrow panes it sits above.
public struct DSFormPicker<Selection: Hashable, Options: View>: View {
    private let title: String
    @Binding private var selection: Selection
    private let identifier: String
    private let labelPlacement: DSTextField.LabelPlacement
    private let options: Options

    public init(_ title: String, selection: Binding<Selection>, identifier: String,
                labelPlacement: DSTextField.LabelPlacement = .top,
                @ViewBuilder options: () -> Options) {
        self.title = title
        self._selection = selection
        self.identifier = identifier
        self.labelPlacement = labelPlacement
        self.options = options()
    }

    public var body: some View {
        switch labelPlacement {
        case .leading:
            DSFormRow(title) {
                picker
                    .controlSize(.large)
                    .fixedSize()
            }
        case .top:
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(title)
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .accessibilityHidden(true)
                picker
            }
        case .hidden:
            picker
        }
    }

    private var picker: some View {
        Picker(title, selection: $selection) { options }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(DSTypography.body)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(title)
    }
}
