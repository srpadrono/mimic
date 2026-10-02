import SwiftUI

public enum DSFormMetrics {
    /// A local port needs five digits, not half the width of a settings sheet.
    public static let portFieldWidth: CGFloat = 80
    /// A multi-section sheet keeps enough width for code and aligned inputs.
    public static let multiSectionWidth: CGFloat = DSSheetWidth.medium
    public static let minimumTallSheetHeight: CGFloat = 500
    public static let maximumTallSheetHeight: CGFloat = 720
    public static let screenVerticalAllowance: CGFloat = 160
    /// The journey step editor shows its common fields without a full-height settings sheet, at
    /// the journey step design's height.
    public static let journeyStepHeight: CGFloat = 696
    /// Short controls beside a route or a longer value.
    public static let compactFieldWidth: CGFloat = 112
    /// A row inside a grouped settings section.
    public static let groupRowHeight: CGFloat = 40
    /// A row's side inset inside a grouped settings section.
    public static let groupRowInset: CGFloat = 14
}

/// A titled group of settings rows: an 11pt heading over a rounded card with hairline rules
/// between its rows. Put ``DSFormGroupRow``s or ``DSFormToggle``s inside, separated by ``DSDivider``.
public struct DSFormSection<Content: View>: View {
    private let title: String
    private let identifier: String
    private let content: Content

    public init(_ title: String, identifier: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.identifier = identifier
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DSTypography.captionSemibold)
                .foregroundStyle(DSColors.labelTertiary)
                .padding(.horizontal, DSSpacing.xs)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DSFormMetrics.groupRowInset)
                .background {
                    RoundedRectangle(cornerRadius: DSCornerRadius.panel).fill(DSColors.raised)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: DSCornerRadius.panel)
                        .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.formSection.\(identifier)")
    }
}

/// One row of a grouped settings section: a title on the leading edge and its control trailing.
public struct DSFormGroupRow<Content: View>: View {
    private let title: String
    private let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: DSSpacing.md) {
            Text(title)
                .font(DSTypography.body)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            content
        }
        .padding(.vertical, DSSpacing.sm)
        .frame(minHeight: DSFormMetrics.groupRowHeight)
    }
}
