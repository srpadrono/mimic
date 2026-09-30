import SwiftUI

/// A status as a dot and the code in one colour. One style everywhere, never a fill.
public struct DSStatusLabel: View {
    public enum Style {
        /// SF Mono: a code in a row or table.
        case code
        /// SF Pro: a word like "Running" or "3 unmatched".
        case text
    }

    private let text: String
    private let color: Color
    private let showsDot: Bool
    private let style: Style

    @Environment(\.backgroundProminence) private var prominence

    /// An HTTP status, optionally followed by its reason phrase. `nil` is a transport failure.
    public init(statusCode: Int?, reason: String? = nil) {
        if let statusCode {
            text = reason.map { "\(statusCode) \($0)" } ?? "\(statusCode)"
            color = DSColors.httpStatusColor(for: statusCode)
        } else {
            text = reason ?? "Failed"
            color = DSColors.error
        }
        showsDot = true
        style = .code
    }

    /// A state in words, coloured by its tone.
    public init(_ text: String, color: Color, showsDot: Bool = true, style: Style = .text) {
        self.text = text
        self.color = color
        self.showsDot = showsDot
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                Circle()
                    .fill(ink)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(style == .code ? DSTypography.status : DSTypography.calloutMedium)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var ink: Color {
        prominence == .increased ? .white : color
    }
}
