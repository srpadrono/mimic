import SwiftUI

/// Selectable monospaced text in a standard input well, with horizontal scrolling for long lines.
public struct DSCodeBlock: View {
    private let content: String
    private let identifier: String

    public init(_ content: String, identifier: String) {
        self.content = content
        self.identifier = identifier
    }

    public var body: some View {
        ScrollView(.horizontal) {
            Text(content)
                .font(DSTypography.code)
                .foregroundStyle(DSColors.labelPrimary)
                .textSelection(.enabled)
        }
        .scrollIndicators(.automatic)
        .padding(DSSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                .fill(DSColors.tertiary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                .strokeBorder(DSColors.border, lineWidth: DSStroke.hairline)
        }
        .accessibilityIdentifier("ds.code.\(identifier)")
        .accessibilityLabel(content)
    }
}
