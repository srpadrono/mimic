import SwiftUI

/// The table look the request log and the import review share: plain column titles over a hairline,
/// fixed columns with 8pt cell padding, zebra rows, and the selection fill.
///
/// Only the look lives here. Sorting, selection, focus, menus and identifiers belong to the section
/// that owns the data, so each feature builds its rows from these pieces and keeps its own behaviour.
nonisolated public enum DSTable {
    /// The padding inside every cell, on either side.
    public static let cellPadding: CGFloat = DSSpacing.sm

    /// The fill a row wears: the selection (the accent while the table has focus, grey without it),
    /// the pointer's wash, or the zebra stripe on odd rows.
    public static func rowFill(
        index: Int,
        isSelected: Bool = false,
        isEmphasized: Bool = true,
        isHovered: Bool = false
    ) -> Color {
        if isSelected { return isEmphasized ? DSColors.selection : DSColors.selectionInactive }
        if isHovered { return DSColors.hover }
        return index % 2 == 0 ? .clear : DSColors.zebra
    }
}

public extension View {
    /// One table cell: `DSTable.cellPadding` inside a fixed column, or the width the other columns
    /// leave when `width` is `nil`.
    func dsTableCell(width: CGFloat?, alignment: Alignment = .leading) -> some View {
        self
            .padding(.horizontal, DSTable.cellPadding)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }

    /// A row's height, fill and ink. A selected row in a focused table is filled with the selection
    /// colour, and its `DSMethodLabel`, `DSStatusLabel` and any text that reads
    /// `backgroundProminence` turn white.
    func dsTableRow(
        index: Int,
        isSelected: Bool = false,
        isEmphasized: Bool = true,
        isHovered: Bool = false,
        height: CGFloat = DSRowHeight.table
    ) -> some View {
        self
            .frame(height: height)
            .background(DSTable.rowFill(index: index, isSelected: isSelected,
                                        isEmphasized: isEmphasized, isHovered: isHovered))
            .environment(\.backgroundProminence, isSelected && isEmphasized ? .increased : .standard)
    }
}

/// A column title: 11pt semibold in the secondary label colour, primary while sorted or under the
/// pointer, with a chevron on the sorted column. Visual only; a sortable column wraps it in its
/// feature's own button.
public struct DSTableColumnTitle: View {
    public enum Sort: Sendable {
        case ascending
        case descending
    }

    private let title: String
    private let sort: Sort?
    private let isHighlighted: Bool

    public init(_ title: String, sort: Sort? = nil, isHighlighted: Bool = false) {
        self.title = title
        self.sort = sort
        self.isHighlighted = isHighlighted
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xxs) {
            Text(title)
                .font(DSTypography.captionSemibold)
                .lineLimit(1)
                .foregroundStyle(sort != nil || isHighlighted ? DSColors.labelPrimary : DSColors.labelSecondary)
            if let sort {
                Image(systemName: sort == .ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: DSGlyph.minimum, weight: .bold))
                    .foregroundStyle(DSColors.labelSecondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The header row: the column titles on one 24pt line with a hairline under them. `inset` keeps
/// the titles over a table's inset rows while the hairline runs the table's whole width.
public struct DSTableHeader<Content: View>: View {
    private let height: CGFloat
    private let inset: CGFloat
    private let content: Content

    public init(height: CGFloat = DSRowHeight.table, inset: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.height = height
        self.inset = inset
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, inset)
        .frame(height: height)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DSColors.separator)
                .frame(height: DSStroke.hairline)
        }
    }
}
