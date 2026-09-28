import SwiftUI

/// A quiet 11pt heading over a group of rows, with an optional trailing control.
public struct DSSectionHeader<Trailing: View>: View {
    private let title: String
    private let identifier: String
    private let horizontalPadding: CGFloat
    private let trailingAction: Trailing?

    public init(
        _ title: String,
        identifier: String,
        horizontalPadding: CGFloat = DSSpacing.md,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.identifier = identifier
        self.horizontalPadding = horizontalPadding
        self.trailingAction = trailing()
    }

    public var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Text(title)
                .font(DSTypography.captionSemibold)
                .foregroundStyle(DSColors.labelTertiary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            if let trailingAction {
                trailingAction
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(minHeight: DSRowHeight.table)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.sectionheader.\(identifier)")
    }
}

extension DSSectionHeader where Trailing == EmptyView {
    public init(_ title: String, identifier: String, horizontalPadding: CGFloat = DSSpacing.md) {
        self.title = title
        self.identifier = identifier
        self.horizontalPadding = horizontalPadding
        self.trailingAction = nil
    }
}
