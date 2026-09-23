import SwiftUI

public enum DSFormMetrics {
    /// A local port needs five digits, not half the width of a settings sheet.
    public static let portFieldWidth: CGFloat = 112
    /// A multi-section sheet keeps enough width for code and aligned inputs.
    public static let multiSectionWidth: CGFloat = 560
    public static let minimumTallSheetHeight: CGFloat = 500
    public static let maximumTallSheetHeight: CGFloat = 720
    public static let screenVerticalAllowance: CGFloat = 160
    /// The journey step editor shows its common fields without a full-height settings sheet.
    public static let journeyStepHeight: CGFloat = 640
    /// Short controls beside a route or a longer value.
    public static let compactFieldWidth: CGFloat = 112
}

/// A section of editable settings on a sheet. The title, inset, surface and rule stay the same
/// whether the section contains one field or a complete backend configuration.
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
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(DSTypography.controlLabel)
                .foregroundStyle(DSColors.labelPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DSSpacing.lg)
                .frame(height: DSBarHeight.controlRow)
                .background(DSColors.band)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(DSColors.separator).frame(height: DSStroke.hairline)
                }

            VStack(alignment: .leading, spacing: DSSpacing.md) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DSSpacing.lg)
        }
        .background(DSColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.lgPlus))
        .overlay {
            RoundedRectangle(cornerRadius: DSCornerRadius.lgPlus)
                .stroke(DSColors.border, lineWidth: DSStroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.formSection.\(identifier)")
    }
}
