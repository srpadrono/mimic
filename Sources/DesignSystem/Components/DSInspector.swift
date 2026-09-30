import SwiftUI

/// Inspector chrome shares the navigator's rhythm without painting over the system material.
public enum DSInspectorMetrics {
    public static let footerHeight = DSBarHeight.footer
    public static let rowHeight = DSRowHeight.list
    /// Text and fields sit 16pt in; selectable rows sit 8pt in so their rounded fill has room.
    public static let inset = DSSpacing.lg
    public static let rowInset = DSSpacing.sm
    public static let iconSlot = DSSpacing.lg
    public static let labelColumn = DSLayout.inspectorLabelWidth
    public static let statusColumn: CGFloat = 36
}

/// Quiet section labels, sharing one content inset rather than a stack of filled bands.
public struct DSInspectorSectionHeader: View {
    private let title: String
    private let identifier: String
    public init(_ title: String, identifier: String) {
        self.title = title
        self.identifier = identifier
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Rectangle().fill(DSColors.separator).frame(height: DSStroke.hairline)
            Text(title)
                .font(DSTypography.bodySemibold)
                .foregroundStyle(DSColors.labelPrimary)
                .accessibilityAddTraits(.isHeader)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DSSpacing.lg)
            .padding(.bottom, DSSpacing.xs + 2)
            .padding(.horizontal, DSInspectorMetrics.inset)
            .accessibilityIdentifier("ds.sectionheader.\(identifier)")
    }
}

public struct DSInspectorValueRow: View {
    private let label: String
    private let value: String
    private let color: Color
    private let identifier: String
    public init(_ label: String, value: String, color: Color = DSColors.labelPrimary, identifier: String) {
        self.label = label
        self.value = value
        self.color = color
        self.identifier = identifier
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.md) {
            Text(label)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .frame(width: DSInspectorMetrics.labelColumn, alignment: .leading)
            Text(value)
                .font(DSTypography.callout)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSInspectorMetrics.inset)
        .frame(minHeight: DSRowHeight.list)
        .accessibilityRepresentation {
            Text("\(label): \(value)").accessibilityIdentifier(identifier)
        }
    }
}

/// Compact aligned status text. HTTP errors remain readable without adding a badge to every row.
public struct DSInspectorStatus: View {
    private let statusCode: Int?
    private let failure: String?
    public init(statusCode: Int?, failure: String? = nil) {
        self.statusCode = statusCode
        self.failure = failure
    }
    public var body: some View {
        DSStatusLabel(statusCode: failure == nil ? statusCode : nil, reason: failure)
    }
}
