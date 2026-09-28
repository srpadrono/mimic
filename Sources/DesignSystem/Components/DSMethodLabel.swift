import SwiftUI

/// An HTTP method as coloured monospaced text. No pill: hue and lightness carry it, and a selected
/// row turns it white with the rest of the row.
public struct DSMethodLabel: View {
    private let method: String
    private let fixedWidth: Bool
    private let identifier: String

    @Environment(\.backgroundProminence) private var prominence

    /// - Parameter fixedWidth: true in lists, where methods sit in one column.
    public init(_ method: String, fixedWidth: Bool = true, identifier: String) {
        self.method = method.uppercased()
        self.fixedWidth = fixedWidth
        self.identifier = identifier
    }

    public var body: some View {
        Text(method)
            .font(DSTypography.method)
            .tracking(0.2)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(prominence == .increased ? Color.white : DSColors.methodColor(for: method))
            .frame(width: fixedWidth ? DSLayout.methodColumn : nil, alignment: .leading)
            .accessibilityIdentifier("ds.method.\(identifier)")
            .accessibilityLabel("\(method) method")
    }
}
