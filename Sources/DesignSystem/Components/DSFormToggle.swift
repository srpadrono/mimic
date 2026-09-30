import SwiftUI

/// A settings row: a title, an optional one-line explanation under it, and a small switch at the
/// trailing edge.
public struct DSFormToggle: View {
    private let title: String
    private let description: String?
    @Binding private var isOn: Bool
    private let identifier: String

    public init(_ title: String, description: String? = nil, isOn: Binding<Bool>, identifier: String) {
        self.title = title
        self.description = description
        self._isOn = isOn
        self.identifier = identifier
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(title)
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelPrimary)
                if let description {
                    Text(description)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, description == nil ? 0 : DSSpacing.sm)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(DSColors.accent)
        .frame(maxWidth: .infinity, minHeight: DSFormMetrics.groupRowHeight)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityHint(description ?? "")
    }
}
