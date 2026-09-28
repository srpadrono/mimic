import SwiftUI

/// A one-pixel rule in the separator colour.
public struct DSDivider: View {
    private let axis: Axis
    private let identifier: String

    public init(axis: Axis = .horizontal, identifier: String = "default") {
        self.axis = axis
        self.identifier = identifier
    }

    public var body: some View {
        Rectangle()
            .fill(DSColors.separator)
            .frame(
                width: axis == .vertical ? DSStroke.hairline : nil,
                height: axis == .horizontal ? DSStroke.hairline : nil
            )
            .accessibilityHidden(true)
            .accessibilityIdentifier("ds.divider.\(identifier)")
    }
}
