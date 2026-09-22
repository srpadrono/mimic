import SwiftUI

/// Inspector chrome shares the navigator's rhythm without painting over the system material.
public enum DSInspectorMetrics {
    public static let headerHeight = DSNavigatorMetrics.headerHeight
    public static let footerHeight = DSNavigatorMetrics.footerHeight
    public static let rowHeight = DSRowHeight.compactRow
    public static let inset = DSNavigatorMetrics.inset
    public static let iconSlot = DSNavigatorMetrics.iconSlot
    public static let labelColumn: CGFloat = 104
    public static let statusColumn: CGFloat = 36
}

public struct DSInspectorHeader<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        HStack(spacing: DSSpacing.smPlus) { content }
            .padding(.horizontal, DSInspectorMetrics.inset)
            .frame(maxWidth: .infinity)
            .frame(height: DSInspectorMetrics.headerHeight)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DSColors.separator).frame(height: DSStroke.hairline)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inspector.header")
    }
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
        Text(title)
            .font(DSTypography.labelMedium)
            .foregroundStyle(DSColors.labelSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DSSpacing.smPlus)
            .padding(.bottom, DSSpacing.xs)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DSColors.separator).frame(height: DSStroke.hairline)
            }
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
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.smPlus) {
            Text(label)
                .font(DSTypography.labelMedium)
                .foregroundStyle(DSColors.labelSecondary)
                .frame(width: DSInspectorMetrics.labelColumn, alignment: .trailing)
            Text(value)
                .font(DSTypography.label)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSInspectorMetrics.inset)
        .padding(.vertical, DSSpacing.xs)
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
        Text(failure ?? statusCode.map(String.init) ?? "—")
            .font(DSTypography.codeSmall)
            .foregroundStyle(
                failure != nil ? DSColors.destructiveText
                    : statusCode.map(DSColors.httpStatusColor(for:)) ?? DSColors.labelSecondary
            )
    }
}
