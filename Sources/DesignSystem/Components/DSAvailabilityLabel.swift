import SwiftUI

/// "✓ Available" or "In use" beside a port field. The glyph differs as well as the colour, so the
/// answer survives without colour.
public struct DSAvailabilityLabel: View {
    private let isAvailable: Bool
    private let identifier: String

    public init(isAvailable: Bool, identifier: String) {
        self.isAvailable = isAvailable
        self.identifier = identifier
    }

    private var text: String { isAvailable ? "Available" : "In use" }

    public var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: isAvailable ? "checkmark" : "exclamationmark.triangle.fill")
                .font(.system(size: DSGlyph.field - 1, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(DSTypography.caption)
        }
        .foregroundStyle(isAvailable ? DSColors.success : DSColors.warning)
        .accessibilityElement()
        .accessibilityLabel(isAvailable ? "Port available" : "Port in use")
        .accessibilityValue(text)
        .accessibilityIdentifier(identifier)
    }
}
